{{ config(
     enabled = var('quality_measures_enabled',var('claims_enabled',var('clinical_enabled',var('tuva_marts_enabled',False))))
    | as_bool
   )
}}

with denominator as (

    select
          patient_id
        , measure_id
        , measure_name
        , measure_version
        , performance_period_begin
        , performance_period_end
    from {{ ref('quality_measures__int_cqm236_denominator') }}

)

, encounters as (

    select
          patient_id
        , encounter_type
        , encounter_start_date
        , encounter_end_date
    from {{ ref('quality_measures__stg_core__encounter') }}

)

, observations as (

    select
          patient_id
        , observation_date
        , normalized_code
        , normalized_description
        , result
    from {{ ref('quality_measures__stg_core__observation') }}
    where lower(normalized_description) in 
        (
              'systolic blood pressure'
            , 'diastolic blood pressure'
        )
        and normalized_code not in (
              '99473' -- Self-measured blood pressure using a device validated for clinical accuracy; patient education/training and device calibration
            , '99474' -- Separate self-measurements of two readings one minute apart, twice daily over a 30-day period (minimum of 12 readings), collection of data reported by the patient and/or caregiver to the physician or other qualified health care professional, with report of average systolic and diastolic pressures and subsequent communication of a treatment plan to the patient
        )

)

, labs as (

    select 
          patient_id
        , result_date
        , collection_date
        , result
        , normalized_code
    from {{ref('quality_measures__stg_core__lab_result')}}
    where normalized_code in 
    ('8480-6' --systolic
    ,'8462-4') --diastolic
    and
    normalized_code_type = 'loinc'

)

, observations_within_range as (

    select
          observations.patient_id
        , observations.observation_date
        , observations.normalized_code
        , observations.normalized_description
        , observations.result
        , denominator.measure_id
        , denominator.measure_name
        , denominator.measure_version
        , denominator.performance_period_begin
        , denominator.performance_period_end
    from observations
    inner join denominator
        on observations.patient_id = denominator.patient_id
        and observations.observation_date between 
            denominator.performance_period_begin and denominator.performance_period_end

)

, labs_within_range as (

    select
          labs.patient_id
        , labs.normalized_code
        , labs.result_date
        , labs.collection_date
        , labs.result
        , denominator.measure_id
        , denominator.measure_name
        , denominator.measure_version
        , denominator.performance_period_begin
        , denominator.performance_period_end
    from labs
    inner join denominator
        on labs.patient_id = denominator.patient_id
        and coalesce(labs.result_date,labs.collection_date) between 
            denominator.performance_period_begin and denominator.performance_period_end

)

, observations_with_encounters as (

    select
          observations_within_range.patient_id
        , observations_within_range.observation_date
        , observations_within_range.normalized_description
        , observations_within_range.result
        , observations_within_range.normalized_code
        , case
            when lower(encounters.encounter_type) in (
                  'emergency department'
                , 'acute inpatient'
            )
            then 0
            else 1
          end as is_valid_encounter_observation
        , observations_within_range.measure_id
        , observations_within_range.measure_name
        , observations_within_range.measure_version
        , observations_within_range.performance_period_begin
        , observations_within_range.performance_period_end
    from observations_within_range
    left join encounters
        on observations_within_range.patient_id = encounters.patient_id
        and observations_within_range.observation_date between 
            encounters.encounter_start_date and encounters.encounter_end_date

)

, obs_and_labs as (

    select
          patient_id
        , observation_date
        , cast(result as {{ dbt.type_float() }}) as bp_reading
        , normalized_description
        , measure_id
        , measure_name
        , measure_version
        , performance_period_begin
        , performance_period_end
        , normalized_code
    from observations_with_encounters
    where is_valid_encounter_observation = 1

    union all

    select
          patient_id
        , coalesce(labs.result_date,collection_date) as observation_date
        , cast(result as {{ dbt.type_float() }}) as bp_reading
        , cast(null as {{ dbt.type_string() }}) as normalized_description
        , measure_id
        , measure_name
        , measure_version
        , performance_period_begin
        , performance_period_end
        , normalized_code
    from labs_within_range labs
)

, systolic_bp as (

    select
          patient_id
        , observation_date
        , bp_reading
        , measure_id
        , measure_name
        , measure_version
        , performance_period_begin
        , performance_period_end
        , row_number() over(partition by patient_id order by observation_date desc, bp_reading asc) as rn
    from obs_and_labs
    where lower(normalized_description) = 'systolic blood pressure'
    or
    normalized_code = '8480-6'

)

, diastolic_bp as (

    select
          patient_id
        , observation_date
        , bp_reading
        , row_number() over(partition by patient_id order by observation_date desc, bp_reading asc) as rn
    from obs_and_labs
    where lower(normalized_description) = 'diastolic blood pressure'
    or
    normalized_code = '8462-4'

)

, least_recent_systolic_bp as (

    select
          patient_id
        , observation_date
        , bp_reading as systolic_bp
        , measure_id
        , measure_name
        , measure_version
        , performance_period_begin
        , performance_period_end
    from systolic_bp
    where rn = 1

)

, least_recent_diastolic_bp as (

    select
          patient_id
        , observation_date
        , bp_reading as diastolic_bp
    from diastolic_bp
    where rn = 1

)

, patients_with_bp_readings as (

    select
          least_recent_systolic_bp.patient_id
        , least_recent_systolic_bp.systolic_bp
        , least_recent_diastolic_bp.diastolic_bp
        , least_recent_systolic_bp.observation_date
        , least_recent_systolic_bp.measure_id
        , least_recent_systolic_bp.measure_name
        , least_recent_systolic_bp.measure_version
        , least_recent_systolic_bp.performance_period_begin
        , least_recent_systolic_bp.performance_period_end
    from least_recent_systolic_bp
    inner join least_recent_diastolic_bp
        on least_recent_systolic_bp.patient_id = least_recent_diastolic_bp.patient_id
            and least_recent_systolic_bp.observation_date = least_recent_diastolic_bp.observation_date

)

, numerator as (

    select
          patient_id
        , observation_date
        , performance_period_begin
        , performance_period_end
        , measure_id
        , measure_name
        , measure_version
        , case
            when systolic_bp < 140.0 and diastolic_bp < 90.0
            then 1
            else 0
          end as numerator_flag
    from patients_with_bp_readings

)

, add_data_types as (

     select distinct
          cast(patient_id as {{ dbt.type_string() }}) as patient_id
        , cast(performance_period_begin as date) as performance_period_begin
        , cast(performance_period_end as date) as performance_period_end
        , cast(measure_id as {{ dbt.type_string() }}) as measure_id
        , cast(measure_name as {{ dbt.type_string() }}) as measure_name
        , cast(measure_version as {{ dbt.type_string() }}) as measure_version
        , cast(observation_date as date) as observation_date
        , cast(numerator_flag as integer) as numerator_flag
    from numerator

)

select
      patient_id
    , performance_period_begin
    , performance_period_end
    , measure_id
    , measure_name
    , measure_version
    , observation_date
    , numerator_flag
from add_data_types
