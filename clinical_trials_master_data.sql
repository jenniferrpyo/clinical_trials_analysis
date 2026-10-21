with params as (
	select date '2026-09-12' as snapshot_date
),
top_areas as (
	select qualifier as area_code, mesh_term as area_name
	from ctgov.mesh_terms
	where tree_number = qualifier
		and (qualifier like 'C%' or qualifier = 'F03')
),
trial_area_all as (
	select distinct bc.nct_id, ta.area_code, ta.area_name
	from ctgov.browse_conditions bc
	join ctgov.mesh_terms mt
		on bc.downcase_mesh_term = mt.downcase_mesh_term
	join top_areas ta
		on left(mt.tree_number, 3) = ta.area_code
	where bc.mesh_type = 'mesh-list'
),
area_priority as (
	select area_name,
		row_number() over (
			order by (area_name = 'Pathological Conditions, Signs and Symptoms'),
					count(distinct nct_id) desc
		) as priority
	from trial_area_all
	group by area_name
),
trial_therapeutic_area as (
	select t.nct_id,
		t.area_name as therapeutic_area,
		row_number() over (partition by t.nct_id order by p.priority) as rn
	from trial_area_all t
	join area_priority p on p.area_name = t.area_name
),
trial_area_count as (
	select nct_id, count(distinct area_name) as n_areas
	from trial_area_all
	group by nct_id
)
select
	s.nct_id,
	s.overall_status,
	s.phase,
	-- Dates and their types (types drive the sensitivity analysis)
	s.start_date,
	s.start_date_type,
	s.completion_date,
	s.completion_date_type,
	s.primary_completion_date,
	s.primary_completion_date_type,
	s.study_first_submitted_date,      -- for left truncation (late registration)
	s.last_update_posted_date,         -- for spotting stale statuses
	-- End of follow-up chosen by STATUS, not by date type
	case
		when s.overall_status in ('COMPLETED', 'TERMINATED')
			then least(s.completion_date, p.snapshot_date)
		when s.overall_status in ('RECRUITING', 'ACTIVE_NOT_RECRUITING',
								  'ENROLLING_BY_INVITATION', 'SUSPENDED')
			then p.snapshot_date
		else null                      -- WITHDRAWN / not started: no real follow-up
	end as end_date,
	case
		when s.overall_status in ('COMPLETED', 'TERMINATED')
			then coalesce(s.completion_date_type, 'MISSING')
		when s.overall_status in ('RECRUITING', 'ACTIVE_NOT_RECRUITING',
								  'ENROLLING_BY_INVITATION', 'SUSPENDED')
			then 'SNAPSHOT'
		else null
	end as end_date_type,
	case
		when s.overall_status in ('COMPLETED', 'TERMINATED')
			then least(s.completion_date, p.snapshot_date) - s.start_date
		when s.overall_status in ('RECRUITING', 'ACTIVE_NOT_RECRUITING',
								  'ENROLLING_BY_INVITATION', 'SUSPENDED')
			then p.snapshot_date - s.start_date
		else null
	end as duration_days,
	s.why_stopped,
	-- Enrollment (ACTUAL for stopped trials = post-baseline)
	s.enrollment,
	s.enrollment_type,
	-- Sponsor
	sp.agency_class,
	sp.name as sponsor_name,
	-- Baseline design features
	s.number_of_arms,
	s.has_dmc,
	s.is_fda_regulated_drug,
	d.allocation,
	d.masking,
	d.primary_purpose,
	cv.number_of_facilities,
	cv.has_us_facility,
	-- Therapeutic area
	coalesce(ta.therapeutic_area, 'Other/Unclassified') as therapeutic_area,
	coalesce(ac.n_areas, 0) as n_areas
from ctgov.studies s
cross join params p
join ctgov.sponsors sp
	on sp.nct_id = s.nct_id
	and sp.lead_or_collaborator = 'lead'
left join ctgov.designs d
	on d.nct_id = s.nct_id
left join ctgov.calculated_values cv
	on cv.nct_id = s.nct_id
left join trial_therapeutic_area ta
	on ta.nct_id = s.nct_id
	and ta.rn = 1
left join trial_area_count ac
	on ac.nct_id = s.nct_id
where s.phase in ('PHASE2', 'PHASE3', 'PHASE2/PHASE3')
order by s.nct_id;