/*****************************************************************************
 * football-psych-ability : SAS Viya modelling (v2 - psych + technical + physical)
 *
 * Pulls player attributes from Supabase and fits, with OVERALL as the target:
 *   - group-only OLS models:  psych_v2, tech_v2, phys_v2   (standalone R2 per group)
 *   - full OLS model:         full_v2   (all 29 predictors, std betas + p-values)
 *   - full decision tree:     fulltree_v2
 *   - per-position OLS fit on the full model -> position_results
 * then POSTs everything back to Supabase.
 *
 * Secrets injected at run time, never committed:
 *   %let supabase_url = ...;  %let supabase_key = <service_role key>;
 *****************************************************************************/

%let psych = mentality_composure mentality_aggression mentality_vision mentality_positioning mentality_penalties mentality_interceptions movement_reactions;
%let tech  = attacking_crossing attacking_finishing attacking_heading_accuracy attacking_short_passing attacking_volleys skill_dribbling skill_curve skill_fk_accuracy skill_long_passing skill_ball_control power_shot_power power_long_shots defending_marking_awareness defending_standing_tackle defending_sliding_tackle;
%let phys  = movement_acceleration movement_sprint_speed movement_agility movement_balance power_jumping power_stamina power_strength;
%let allv  = &psych &tech &phys;
%let cols  = player_id,overall,player_position,%sysfunc(translate(&allv,%str(,),%str( )));

%macro post(table=, fileref=);
  filename _o temp;
  proc http url="&supabase_url./rest/v1/&table" method="POST" in=&fileref out=_o;
    headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
            "Content-Type"="application/json" "Prefer"="resolution=merge-duplicates";
  run;
%mend;

/* pull all attributes (Range-header pagination) */
%macro pull;
  %let page=0; %let more=1;
  %do %while(&more=1);
    %let lo=%eval(&page*1000); %let hi=%eval(&lo+999);
    filename resp temp;
    proc http url="&supabase_url./rest/v1/players?select=&cols" method="GET" out=resp;
      headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key" "Range-Unit"="items" "Range"="&lo.-&hi.";
    run;
    libname j json fileref=resp;
    proc sql noprint; select count(*) into :n trimmed from j.root; quit;
    %if &page=0 %then %do; data players; set j.root; run; %end;
    %else %if &n>0 %then %do; proc append base=players data=j.root force; run; %end;
    %if &n<1000 %then %let more=0;
    libname j clear; %let page=%eval(&page+1);
  %end;
%mend;
%pull;

data players; set players;
  length posgroup $3; _p=upcase(player_position);
  if _p='GK' then posgroup='GK';
  else if _p in ('CB','RB','LB','RWB','LWB') then posgroup='DEF';
  else if _p in ('CDM','CM','CAM','RM','LM') then posgroup='MID';
  else if _p in ('ST','CF','RW','LW') then posgroup='FWD';
  else posgroup='OTH'; drop _p;
run;

ods exclude all;

/* generic OLS fit + post model_results (R2 only) */
%macro fit_group(runid=, name=, vars=, k=);
  proc reg data=players plots=none;
    model overall = &vars;
    output out=_sc p=_p r=_r;
  quit;
  proc sql noprint;
    select count(*) into :nn trimmed from _sc;
    select var(overall) into :vy trimmed from _sc;
    select sum(_r*_r) into :se trimmed from _sc;
  quit;
  data _null_;
    sst=&vy*(&nn-1); r2=1-&se/sst; adj=1-(1-r2)*(&nn-1)/(&nn-&k-1); rmse=sqrt(&se/(&nn-&k-1));
    call symputx('r2',put(r2,8.5)); call symputx('adj',put(adj,8.5)); call symputx('rmse',put(rmse,8.5));
  run;
  filename bg temp;
  data _null_; file bg;
    put "{""run_id"":""&runid"",""model_name"":""&name"",""n_obs"":&nn"
        ",""r_square"":&r2,""adj_r_square"":&adj,""rmse"":&rmse}";
  run;
  %post(table=model_results, fileref=bg)
  %put NOTE: &runid R2=&r2;
%mend;

%fit_group(runid=psych_v2, name=Psychological only (7 vars),  vars=&psych, k=7)
%fit_group(runid=tech_v2,  name=Technical only (15 vars),     vars=&tech,  k=15)
%fit_group(runid=phys_v2,  name=Physical only (7 vars),       vars=&phys,  k=7)

/* FULL model: standardized betas + p-values + grouped coefficients */
ods output ParameterEstimates=pe;
proc reg data=players plots=none;
  model overall = &allv / stb;
  output out=scored p=pred r=resid;
quit;
proc sql noprint;
  select count(*) into :nn trimmed from scored;
  select var(overall) into :vy trimmed from scored;
  select sum(resid*resid) into :se trimmed from scored;
quit;
data _null_;
  sst=&vy*(&nn-1); r2=1-&se/sst; adj=1-(1-r2)*(&nn-1)/(&nn-30); rmse=sqrt(&se/(&nn-30));
  call symputx('r2',put(r2,8.5)); call symputx('adj',put(adj,8.5)); call symputx('rmse',put(rmse,8.5));
run;
filename bf temp;
data _null_; file bf;
  put "{""run_id"":""full_v2"",""model_name"":""Full OLS (29 vars: psych+tech+phys)"",""n_obs"":&nn"
      ",""r_square"":&r2,""adj_r_square"":&adj,""rmse"":&rmse}";
run;
%post(table=model_results, fileref=bf)

data _coef; set pe;
  length json $600 imp $20 grp $14;
  v=lowcase(strip(Variable));
  if v=:'mentality_' or v='movement_reactions' then grp='psychological';
  else if v=:'attacking_' or v=:'skill_' or v=:'defending_' or v='power_shot_power' or v='power_long_shots' then grp='technical';
  else if v=:'movement_' or v='power_jumping' or v='power_stamina' or v='power_strength' then grp='physical';
  else grp='';
  if upcase(Variable)='INTERCEPT' then imp='null'; else imp=strip(put(StandardizedEst,best12.));
  json=cats('{"run_id":"full_v2","variable":"',Variable,'","group":"',grp,
            '","estimate":',Estimate,',"std_error":',StdErr,',"t_value":',tValue,
            ',"p_value":',Probt,',"importance":',imp,'}');
run;
filename bc temp;
data _null_; file bc; set _coef end=last;
  if _n_=1 then put '['; if last then put json; else put json ','; if last then put ']';
run;
%post(table=model_coefficients, fileref=bc)

data _pred; set scored; if not missing(pred);
  length json $300;
  json=cats('{"run_id":"full_v2","player_id":',player_id,',"actual":',overall,
            ',"predicted":',round(pred,0.01),',"residual":',round(resid,0.01),
            ',"player_position":"',posgroup,'"}');
run;
filename bp temp;
data _null_; file bp; set _pred end=last;
  if _n_=1 then put '['; if last then put json; else put json ','; if last then put ']';
run;
%post(table=model_predictions, fileref=bp)

/* decision tree on full set */
proc hpsplit data=players maxdepth=10 maxbranch=2 cvmethod=none;
  target overall / level=interval;
  input &allv / level=interval;
  prune off;
  output out=scored_t;
run;
proc sql noprint;
  select count(*) into :tn trimmed from scored_t;
  select 1-sum((overall-P_overall)**2)/((count(*)-1)*var(overall)) into :tr2 trimmed from scored_t;
  select sqrt(mean((overall-P_overall)**2)) into :trm trimmed from scored_t;
quit;
filename bt temp;
data _null_; file bt;
  put "{""run_id"":""fulltree_v2"",""model_name"":""Decision tree (full, depth 10)"",""n_obs"":&tn,""r_square"":&tr2,""rmse"":&trm}";
run;
%post(table=model_results, fileref=bt)

/* per-position fit on full model */
proc sort data=players out=psort; by posgroup; run;
ods output ParameterEstimates=_d;
proc reg data=psort plots=none;
  by posgroup; model overall = &allv; output out=scp p=pp;
quit;
proc sql noprint;
  create table posres as
    select posgroup as position_group, count(*) as n_obs,
           1-sum((overall-pp)**2)/((count(*)-1)*var(overall)) as r_square
    from scp where posgroup ne 'OTH' group by posgroup;
quit;
data _pj; set posres; length json $200;
  json=cats('{"run_id":"full_v2","position_group":"',position_group,'","n_obs":',n_obs,',"r_square":',round(r_square,0.0001),'}');
run;
filename bz temp;
data _null_; file bz; set _pj end=last;
  if _n_=1 then put '['; if last then put json; else put json ','; if last then put ']';
run;
%post(table=position_results, fileref=bz)

ods exclude none;
data summary; length item $28 value $40;
  item='Full OLS R2'; value="&r2"; output;
  item='Full tree R2'; value="&tr2"; output;
run;
proc print data=summary noobs; run;
