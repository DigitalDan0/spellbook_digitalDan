{{
    config(
        schema = 'component_ethereum',
        alias='airdrop_claims',
        materialized = 'table',
        file_format = 'delta',
        tags=['static'],
        unique_key = ['recipient', 'tx_hash', 'evt_index'],
        post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "component",
                                \'["hildobby"]\') }}'
    )
}}

{% set cmp_token_address = '0x9f20ed5f919dc1c1695042542c13adcfc100dcab' %}

WITH early_price AS (
    SELECT MIN(minute) AS minute
    , MIN_BY(price, minute) AS price
    FROM {{ source('prices', 'usd') }}
    WHERE blockchain = 'ethereum'
    AND contract_address='{{cmp_token_address}}'
    )

SELECT 'ethereum' AS blockchain
, t.evt_block_time AS block_time
, t.evt_block_number AS block_number
, 'Component' AS project
, 'Component Airdrop' AS airdrop_identifier
, t.account AS recipient
, t.contract_address
, t.evt_tx_hash AS tx_hash
, CAST(t.amount AS DECIMAL(38,0)) AS amount_raw
, CAST(t.amount/POWER(10, 18) AS double) AS amount_original
, CASE WHEN t.evt_block_time >= (SELECT minute FROM early_price) THEN CAST(pu.price*t.amount/POWER(10, 18) AS double)
    ELSE CAST((SELECT price FROM early_price)*t.amount/POWER(10, 18) AS double)
    END AS amount_usd
, '{{cmp_token_address}}' AS token_address
, 'CMP' AS token_symbol
, t.evt_index
FROM {{ source('component_ethereum', 'MerkleDistributor_evt_Claimed') }} t
LEFT JOIN {{ ref('prices_usd_forward_fill_legacy') }} pu ON pu.blockchain = 'ethereum'
    AND pu.contract_address='{{cmp_token_address}}'
    AND pu.minute=date_trunc('minute', t.evt_block_time)
WHERE t.evt_block_time BETWEEN '2021-04-27' AND '2021-07-29'