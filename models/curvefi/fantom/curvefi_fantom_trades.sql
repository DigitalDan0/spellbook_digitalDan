{{ config(
    alias = 'trades',
    partition_by = ['block_date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index', 'trace_address'],
    )
}}
-- SELECT MIN(evt_block_time) FROM curvefi_fantom.StableSwap_evt_TokenExchange
{% set project_start_date = '2021-02-20 00:00:00' %}

{%- set evt_TokenExchange_sources = [
     source('curvefi_fantom', 'StableSwap_evt_TokenExchange')
] -%}

{%- set evt_TokenExchangeUnderlying_sources = [
     source('curvefi_fantom', 'StableSwap_evt_TokenExchangeUnderlying')
] -%}

WITH exchange_evt_all as (
    {%- for src in evt_TokenExchange_sources %}
    SELECT
        evt_block_time AS block_time,
        buyer AS taker,
        tokens_bought AS token_bought_amount_raw,
        tokens_sold AS token_sold_amount_raw,
        bought_id,
        sold_id,
        contract_address AS project_contract_address,
        evt_tx_hash AS tx_hash,
        evt_index
    FROM {{ src }}
        {%- if is_incremental() %}
        WHERE evt_block_time >= date_trunc("day", now() - interval '1 week')
        {%- endif %}
    {%- if not loop.last %}
    UNION ALL
    {%- endif %}
    {%- endfor %}
),
 
exchange_und_evt_all as (
    {%- for src in evt_TokenExchangeUnderlying_sources %}
    SELECT
        evt_block_time AS block_time,
        buyer AS taker,
        tokens_bought AS token_bought_amount_raw,
        tokens_sold AS token_sold_amount_raw,
        bought_id,
        sold_id,
        contract_address AS project_contract_address,
        evt_tx_hash AS tx_hash,
        evt_index
    FROM {{ src }}
        {%- if is_incremental() %}
        WHERE evt_block_time >= date_trunc("day", now() - interval '1 week')
        {%- endif %}
    {%- if not loop.last %}
    UNION ALL
    {%- endif %}
    {%- endfor %}

),

enriched_evt_all as(
    SELECT
        eb.*
        ,pa.token_address as token_bought_address
        ,pb.token_address as token_sold_address
    FROM exchange_evt_all eb
    INNER JOIN {{ ref('curvefi_fantom_pool_tokens') }} pa
        ON eb.bought_id = pa.token_id
        AND eb.project_contract_address = pa.pool
        AND pa.token_type = 'pool_token'
    INNER JOIN
    {{ ref('curvefi_fantom_pool_tokens') }} pb
        ON eb.sold_id = pb.token_id
        AND eb.project_contract_address = pb.pool
        AND pb.token_type = 'pool_token'

    UNION ALL

    SELECT
        eb.*
        ,pa.token_address as token_bought_address
        ,pb.token_address as token_sold_address
    FROM exchange_und_evt_all eb
    INNER JOIN {{ ref('curvefi_fantom_pool_tokens') }} pa
        ON eb.bought_id = pa.token_id
        AND eb.project_contract_address = pa.pool
        AND pa.token_type = 'underlying_token_bought'
    INNER JOIN
    {{ ref('curvefi_fantom_pool_tokens') }} pb
        ON eb.sold_id = pb.token_id
        AND eb.project_contract_address = pb.pool
        AND pb.token_type = 'underlying_token_sold'
)

SELECT
    'fantom' as blockchain,
    'curve' as project,
    '2' as version,
    TRY_CAST(date_trunc('DAY', dexs.block_time) as date) as block_date,
    dexs.block_time,
    erc20a.symbol as token_bought_symbol,
    erc20b.symbol as token_sold_symbol,
    CASE
        WHEN lower(erc20a.symbol) > lower(erc20b.symbol) THEN concat(erc20b.symbol, '-', erc20a.symbol)
        ELSE concat(erc20a.symbol, '-', erc20b.symbol)
    END as token_pair,
    dexs.token_bought_amount_raw / power(10, erc20a.decimals) as token_bought_amount,
    dexs.token_sold_amount_raw / power(10, erc20b.decimals) as token_sold_amount,
    CAST(dexs.token_bought_amount_raw AS DECIMAL(38,0)) AS token_bought_amount_raw,
    CAST(dexs.token_sold_amount_raw AS DECIMAL(38,0)) AS token_sold_amount_raw,
    COALESCE(
        (dexs.token_bought_amount_raw / power(10, p_bought.decimals)) * p_bought.price,
        (dexs.token_sold_amount_raw / power(10, p_sold.decimals)) * p_sold.price
    ) as amount_usd,
    dexs.token_bought_address,
    dexs.token_sold_address,
    dexs.taker,
    '' as maker,
    dexs.project_contract_address,
    dexs.tx_hash,
    tx.from as tx_from,
    tx.to AS tx_to,
    '' as trace_address,
    dexs.evt_index
FROM enriched_evt_all dexs
INNER JOIN {{ source('fantom', 'transactions') }} tx
    ON tx.hash = dexs.tx_hash
    {% if not is_incremental() %}
    AND tx.block_time >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND tx.block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ ref('tokens_erc20_legacy') }} erc20a
    ON erc20a.contract_address = dexs.token_bought_address
    AND erc20a.blockchain = 'fantom'
LEFT JOIN {{ ref('tokens_erc20_legacy') }} erc20b
    ON erc20b.contract_address = dexs.token_sold_address
    AND erc20b.blockchain = 'fantom'
LEFT JOIN {{ source('prices', 'usd') }} p_bought
    ON p_bought.minute = date_trunc('minute', dexs.block_time)
    AND p_bought.contract_address = dexs.token_bought_address
    AND p_bought.blockchain = 'fantom'
    {% if not is_incremental() %}
    AND p_bought.minute >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_bought.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', dexs.block_time)
    AND p_sold.contract_address = dexs.token_sold_address
    AND p_sold.blockchain = 'fantom'
    {% if not is_incremental() %}
    AND p_sold.minute >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_sold.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
; 