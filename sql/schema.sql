-- Schema for football-psych-ability project (Supabase / Postgres)
-- Run in Supabase SQL editor or via psql.

-- 1. Player-level data: psychological profile + ability target
create table if not exists public.players (
    player_id      bigint primary key,
    short_name     text,
    long_name      text,
    age            int,
    nationality    text,
    club_name      text,
    league_name    text,
    player_position text,
    fifa_version   int,            -- which FIFA edition the row came from
    -- ABILITY (explained variable)
    overall        int,            -- 0-99 overall ability rating
    potential      int,
    -- PSYCHOLOGICAL / MENTALITY PROFILE (predictors)
    mentality_composure     int,
    mentality_aggression    int,
    mentality_vision        int,
    mentality_positioning   int,
    mentality_penalties     int,
    mentality_interceptions int,
    movement_reactions      int,   -- decision speed / game intelligence
    -- TECHNICAL / SKILL (predictors)
    attacking_crossing         int,
    attacking_finishing        int,
    attacking_heading_accuracy int,
    attacking_short_passing    int,
    attacking_volleys          int,
    skill_dribbling            int,
    skill_curve                int,
    skill_fk_accuracy          int,
    skill_long_passing         int,
    skill_ball_control         int,
    power_shot_power           int,
    power_long_shots           int,
    defending_marking_awareness int,
    defending_standing_tackle  int,
    defending_sliding_tackle   int,
    -- PHYSICAL (predictors)
    movement_acceleration  int,
    movement_sprint_speed  int,
    movement_agility       int,
    movement_balance       int,
    power_jumping          int,
    power_stamina          int,
    power_strength         int,
    created_at     timestamptz default now()
);

create index if not exists idx_players_overall on public.players(overall);

-- 2. Model metrics (one row per model run)
create table if not exists public.model_results (
    run_id       text primary key,
    model_name   text,
    target       text default 'overall',
    n_obs        int,
    r_square     numeric,
    adj_r_square numeric,
    rmse         numeric,
    created_at   timestamptz default now()
);

-- 3. Model coefficients / variable importance (long format)
create table if not exists public.model_coefficients (
    run_id     text references public.model_results(run_id) on delete cascade,
    variable   text,
    "group"    text,   -- psychological | technical | physical
    estimate   numeric,
    std_error  numeric,
    t_value    numeric,
    p_value    numeric,
    importance numeric,
    primary key (run_id, variable)
);

-- 4. Predictions (actual vs predicted) for visualization
create table if not exists public.model_predictions (
    run_id          text references public.model_results(run_id) on delete cascade,
    player_id       bigint,
    actual          numeric,
    predicted       numeric,
    residual        numeric,
    player_position text,
    primary key (run_id, player_id)
);

-- 5. Per-position model fit (how well the model works by position group)
create table if not exists public.position_results (
    run_id         text,
    position_group text,
    n_obs          int,
    r_square       numeric,
    primary key (run_id, position_group)
);

-- Allow anonymous read access for the public GitHub Pages site (RLS)
alter table public.players            enable row level security;
alter table public.model_results      enable row level security;
alter table public.model_coefficients enable row level security;
alter table public.model_predictions  enable row level security;
alter table public.position_results   enable row level security;

create policy "public read players"      on public.players            for select using (true);
create policy "public read results"      on public.model_results      for select using (true);
create policy "public read coefficients" on public.model_coefficients for select using (true);
create policy "public read predictions"  on public.model_predictions  for select using (true);
create policy "public read positions"    on public.position_results   for select using (true);
