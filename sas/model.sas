/*****************************************************************************
 * football-psych-ability : SAS Viya modelling
 *
 * Pulls player psychological profile + ability data from Supabase (REST API),
 * models OVERALL ability as a function of the mentality/psychological profile,
 * and POSTs the results (metrics, coefficients, predictions) back to Supabase.
 *
 * Secrets are NOT stored in this file. Before running, define:
 *     %let supabase_url = https://YOURPROJECT.supabase.co;
 *     %let supabase_key = <service_role key>;
 * (These are injected at run time, never committed.)
 *****************************************************************************/

%let run_id   = ols_v1;
%let model_nm = OLS: overall ~ mentality profile;
%let cols = player_id,overall,mentality_composure,mentality_aggression,mentality_vision,mentality_positioning,mentality_penalties,mentality_interceptions,movement_reactions;

/*--- 1. Pull data from Supabase REST (PostgREST), paginated via Range header */
%macro pull_players;
    %let page = 0; %let pagesize = 1000; %let more = 1;
    %do %while (&more = 1);
        %let lo = %eval(&page * &pagesize);
        %let hi = %eval(&lo + &pagesize - 1);
        filename resp temp;
        proc http
            url="&supabase_url./rest/v1/players?select=&cols"
            method="GET" out=resp;
            headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
                    "Range-Unit"="items" "Range"="&lo.-&hi.";
        run;
        libname j json fileref=resp;
        proc sql noprint; select count(*) into :n trimmed from j.root; quit;
        %if &page = 0 %then %do;
            data players; set j.root; run;   /* seed table from first page */
        %end;
        %else %if &n > 0 %then %do;
            proc append base=players data=j.root force; run;
        %end;
        %if &n < &pagesize %then %let more = 0;
        libname j clear;
        %let page = %eval(&page + 1);
    %end;
    proc sql noprint; select count(*) into :nobs trimmed from players; quit;
    %put NOTE: pulled &nobs players from Supabase;
%mend;
%pull_players;

/*--- 2. Model: OVERALL ~ psychological profile (OLS with standardized betas) */
ods output ParameterEstimates=pe;
proc reg data=players plots=none;
    model overall = mentality_composure mentality_aggression mentality_vision
                    mentality_positioning mentality_penalties
                    mentality_interceptions movement_reactions / stb;
    output out=scored p=pred r=resid;
quit;

/*--- 3. Compute fit statistics from the scored data (robust) ---------------*/
%let k = 7;
proc sql noprint;
    select count(*)        into :nobs trimmed from scored;
    select var(overall)    into :vary trimmed from scored;
    select sum(resid*resid) into :sse trimmed from scored;
quit;
data _null_;
    sst = &vary * (&nobs - 1);
    r2  = 1 - &sse/sst;
    adj = 1 - (1 - r2)*(&nobs - 1)/(&nobs - &k - 1);
    rmse = sqrt(&sse/(&nobs - &k - 1));
    call symputx('rsq',   put(r2,  best12.));
    call symputx('adjrsq',put(adj, best12.));
    call symputx('rmse',  put(rmse,best12.));
run;
%put NOTE: R2=&rsq Adj=&adjrsq RMSE=&rmse N=&nobs;

/*--- 4. POST results back to Supabase --------------------------------------*/
/* 4a. model_results (small -> macro var is fine) */
filename body temp;
data _null_;
    file body;
    put '{"run_id":"' "&run_id" '","model_name":"' "&model_nm"
        '","n_obs":' "&nobs" ',"r_square":' "&rsq"
        ',"adj_r_square":' "&adjrsq" ',"rmse":' "&rmse" '}';
run;
filename out temp;
proc http url="&supabase_url./rest/v1/model_results" method="POST" in=body out=out;
    headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
            "Content-Type"="application/json" "Prefer"="resolution=merge-duplicates";
run;
%put NOTE: model_results status=&SYS_PROCHTTP_STATUS_CODE;

/* 4b. model_coefficients -> write JSON array to a file (no macro-var limit) */
data _coef;
    set pe;
    where upcase(Variable) ne 'INTERCEPT';
    length json $500;
    json = cats('{"run_id":"', "&run_id", '","variable":"', Variable,
                '","estimate":', Estimate,
                ',"std_error":', StdErr,
                ',"t_value":', tValue,
                ',"p_value":', Probt,
                ',"importance":', StandardizedEst, '}');
run;
filename body2 temp;
data _null_;
    file body2;
    set _coef end=last;
    if _n_ = 1 then put '[';
    if last then put json; else put json ',';
    if last then put ']';
run;
proc http url="&supabase_url./rest/v1/model_coefficients" method="POST" in=body2 out=out;
    headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
            "Content-Type"="application/json" "Prefer"="resolution=merge-duplicates";
run;
%put NOTE: model_coefficients status=&SYS_PROCHTTP_STATUS_CODE;

/* 4c. model_predictions -> write JSON array to a file */
data _pred;
    set scored;
    if not missing(pred);
    length json $300;
    json = cats('{"run_id":"', "&run_id", '","player_id":', player_id,
                ',"actual":', overall, ',"predicted":', round(pred,0.01),
                ',"residual":', round(resid,0.01), '}');
run;
filename body3 temp;
data _null_;
    file body3;
    set _pred end=last;
    if _n_ = 1 then put '[';
    if last then put json; else put json ',';
    if last then put ']';
run;
proc http url="&supabase_url./rest/v1/model_predictions" method="POST" in=body3 out=out;
    headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
            "Content-Type"="application/json" "Prefer"="resolution=merge-duplicates";
run;
%put NOTE: model_predictions status=&SYS_PROCHTTP_STATUS_CODE;

%put NOTE: Modelling complete. R2=&rsq Adj=&adjrsq RMSE=&rmse N=&nobs;
