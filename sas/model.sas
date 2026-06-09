/*****************************************************************************
 * football-psych-ability : SAS Viya modelling
 *
 * Pulls player psychological profile + ability data from Supabase (REST API),
 * fits TWO models with OVERALL ability as the explained variable:
 *    1. OLS linear regression          (run_id = ols_v1)
 *    2. CART decision tree (PROC HPSPLIT, run_id = tree_v1)
 * plus a per-position breakdown of the OLS fit, and POSTs everything back to
 * Supabase (model_results, model_coefficients, model_predictions,
 * position_results).
 *
 * NOTE: PROC FOREST / HPFOREST (random forest) is not licensed on this Viya,
 * so the nonlinear comparison model is a single regression tree (HPSPLIT).
 *
 * Secrets are injected at run time, never committed:
 *     %let supabase_url = https://YOURPROJECT.supabase.co;
 *     %let supabase_key = <service_role key>;
 *****************************************************************************/

%let model_nm = OLS: overall ~ mentality profile;
%let cols = player_id,overall,player_position,mentality_composure,mentality_aggression,mentality_vision,mentality_positioning,mentality_penalties,mentality_interceptions,movement_reactions;

%macro post(table=, fileref=);
    filename _out temp;
    proc http url="&supabase_url./rest/v1/&table" method="POST" in=&fileref out=_out;
        headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
                "Content-Type"="application/json" "Prefer"="resolution=merge-duplicates";
    run;
%mend;

/*--- 1. Pull data from Supabase (Range-header pagination) -------------------*/
%macro pull;
    %let page = 0; %let more = 1;
    %do %while (&more = 1);
        %let lo = %eval(&page*1000); %let hi = %eval(&lo + 999);
        filename resp temp;
        proc http url="&supabase_url./rest/v1/players?select=&cols" method="GET" out=resp;
            headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
                    "Range-Unit"="items" "Range"="&lo.-&hi.";
        run;
        libname j json fileref=resp;
        proc sql noprint; select count(*) into :n trimmed from j.root; quit;
        %if &page = 0 %then %do; data players; set j.root; run; %end;
        %else %if &n > 0 %then %do; proc append base=players data=j.root force; run; %end;
        %if &n < 1000 %then %let more = 0;
        libname j clear; %let page = %eval(&page + 1);
    %end;
%mend;
%pull;

/* position groups */
data players;
    set players;
    length posgroup $3;
    _p = upcase(player_position);
    if _p = 'GK' then posgroup = 'GK';
    else if _p in ('CB','RB','LB','RWB','LWB') then posgroup = 'DEF';
    else if _p in ('CDM','CM','CAM','RM','LM') then posgroup = 'MID';
    else if _p in ('ST','CF','RW','LW')        then posgroup = 'FWD';
    else posgroup = 'OTH';
    drop _p;
run;

%let preds = mentality_composure mentality_aggression mentality_vision
             mentality_positioning mentality_penalties mentality_interceptions
             movement_reactions;

/*======================= MODEL 1: OLS =====================================*/
ods exclude all;
ods output ParameterEstimates=pe;
proc reg data=players plots=none;
    model overall = &preds / stb;
    output out=scored p=pred r=resid;
quit;

%let k = 7;
proc sql noprint;
    select count(*) into :nobs trimmed from scored;
    select var(overall) into :vary trimmed from scored;
    select sum(resid*resid) into :sse trimmed from scored;
quit;
data _null_;
    sst = &vary*(&nobs-1); r2 = 1 - &sse/sst;
    adj = 1 - (1-r2)*(&nobs-1)/(&nobs-&k-1); rmse = sqrt(&sse/(&nobs-&k-1));
    call symputx('rsq',put(r2,8.5)); call symputx('adjrsq',put(adj,8.5));
    call symputx('rmse',put(rmse,8.5));
run;

/* model_results (OLS) */
filename b1 temp;
data _null_; file b1;
    put '{"run_id":"ols_v1","model_name":"' "&model_nm"
        '","n_obs":' "&nobs" ',"r_square":' "&rsq"
        ',"adj_r_square":' "&adjrsq" ',"rmse":' "&rmse" '}';
run;
%post(table=model_results, fileref=b1)

/* coefficients (OLS, incl. intercept for the interactive predictor) */
data _coef; set pe;
    length json $500 imp $20;
    if upcase(Variable)='INTERCEPT' then imp='null';
    else imp = strip(put(StandardizedEst, best12.));
    json = cats('{"run_id":"ols_v1","variable":"', Variable,
                '","estimate":', Estimate, ',"std_error":', StdErr,
                ',"t_value":', tValue, ',"p_value":', Probt,
                ',"importance":', imp, '}');
run;
filename b2 temp;
data _null_; file b2; set _coef end=last;
    if _n_=1 then put '['; if last then put json; else put json ','; if last then put ']';
run;
%post(table=model_coefficients, fileref=b2)

/* predictions (OLS, with position group) */
data _pred; set scored;
    if not missing(pred);
    length json $300;
    json = cats('{"run_id":"ols_v1","player_id":', player_id,
                ',"actual":', overall, ',"predicted":', round(pred,0.01),
                ',"residual":', round(resid,0.01),
                ',"player_position":"', posgroup, '"}');
run;
filename b3 temp;
data _null_; file b3; set _pred end=last;
    if _n_=1 then put '['; if last then put json; else put json ','; if last then put ']';
run;
%post(table=model_predictions, fileref=b3)

/*======================= MODEL 2: Decision tree (HPSPLIT) =================*/
proc hpsplit data=players maxdepth=12 maxbranch=2;
    target overall / level=interval;
    input &preds / level=interval;
    output out=scored_t;
run;
proc sql noprint;
    select count(*) into :tn trimmed from scored_t;
    select 1 - sum((overall-P_overall)**2)/((count(*)-1)*var(overall))
        into :tr2 trimmed from scored_t;
    select sqrt(mean((overall-P_overall)**2)) into :trmse trimmed from scored_t;
quit;
filename b4 temp;
data _null_; file b4;
    put '{"run_id":"tree_v1","model_name":"Decision tree (HPSPLIT, depth<=12)"'
        ',"n_obs":' "&tn" ',"r_square":' "&tr2" ',"rmse":' "&trmse" '}';
run;
%post(table=model_results, fileref=b4)

/*======================= Per-position OLS fit ============================*/
proc sort data=players out=psort; by posgroup; run;
ods output ParameterEstimates=_drop;
proc reg data=psort plots=none;
    by posgroup;
    model overall = &preds;
    output out=scored_p p=pp;
quit;
proc sql noprint;
    create table posres as
        select posgroup as position_group, count(*) as n_obs,
               1 - sum((overall-pp)**2)/((count(*)-1)*var(overall)) as r_square
        from scored_p where posgroup ne 'OTH' group by posgroup;
quit;
data _posj; set posres;
    length json $200;
    json = cats('{"run_id":"ols_v1","position_group":"', position_group,
                '","n_obs":', n_obs, ',"r_square":', round(r_square,0.0001), '}');
run;
filename b5 temp;
data _null_; file b5; set _posj end=last;
    if _n_=1 then put '['; if last then put json; else put json ','; if last then put ']';
run;
%post(table=position_results, fileref=b5)

/*--- compact summary -------------------------------------------------------*/
ods exclude none;
data summary;
    length item $24 value $40;
    item='OLS N';          value="&nobs";  output;
    item='OLS R2';         value="&rsq";   output;
    item='OLS RMSE';       value="&rmse";  output;
    item='Tree R2';        value="&tr2";   output;
    item='Tree RMSE';      value="&trmse"; output;
run;
proc print data=summary noobs; run;
proc print data=posres noobs; run;
