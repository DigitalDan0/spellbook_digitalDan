{{
    config(
        materialized='incremental',
        schema='safe_celo',
        alias='transfers',
        partition_by = ['block_date'],
        unique_key = ['block_date', 'address', 'tx_hash', 'trace_address'],
        on_schema_change='fail',
        file_format ='delta',
        incremental_strategy='merge',
        post_hook='{{ expose_spells(\'["celo"]\',
                                    "project",
                                    "safe",
                                    \'["danielpartida"]\') }}'
    )
}}

{% set project_start_date = '2021-06-20' %}

select
    s.address,
    try_cast(date_trunc('day', et.block_time) as date) as block_date,
    et.block_time,
    -et.value as amount_raw,
    et.tx_hash,
    array_join(et.trace_address, ',') as trace_address
from {{ source('celo', 'traces') }} et
inner join {{ ref('safe_celo_safes') }} s on et.from = s.address
    and et.from != et.to -- exclude calls to self to guarantee unique key property
    and et.success = true
    and (lower(et.call_type) not in ('delegatecall', 'callcode', 'staticcall') or et.call_type is null)
    and et.value > '0' -- value is of type string. exclude 0 value traces
{% if not is_incremental() %}
where et.block_time > '{{project_start_date}}' -- for initial query optimisation
{% endif %}
{% if is_incremental() %}
-- to prevent potential counterfactual safe deployment issues we take a bigger interval
where et.block_time > date_trunc("day", now() - interval '10 days')
{% endif %}

union all

select
    s.address,
    try_cast(date_trunc('day', et.block_time) as date) as block_date,
    et.block_time,
    et.value as amount_raw,
    et.tx_hash,
    array_join(et.trace_address, ',') as trace_address
from {{ source('celo', 'traces') }} et
inner join {{ ref('safe_celo_safes') }} s on et.to = s.address
    and et.from != et.to -- exclude calls to self to guarantee unique key property
    and et.success = true
    and (lower(et.call_type) not in ('delegatecall', 'callcode', 'staticcall') or et.call_type is null)
    and et.value > '0' -- value is of type string. exclude 0 value traces
{% if not is_incremental() %}
where et.block_time > '{{project_start_date}}' -- for initial query optimisation
{% endif %}
{% if is_incremental() %}
-- to prevent potential counterfactual safe deployment issues we take a bigger interval
where et.block_time > date_trunc("day", now() - interval '10 days')
{% endif %}
