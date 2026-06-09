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

%let run_id    = glmselect_v1;
%let model_nm  = GLMSELECT stepwise (mentality -> overall);

/*--- 1. Pull data from Supabase REST (PostgREST), paginated -----------------*/
%macro pull_players;
    %let page = 0;
    %let pagesize = 1000;
    %let more = 1;
    data players; stop; run;  /* empty shell */
    %do %while (&more = 1);
        %let off = %eval(&page * &pagesize);
        filename resp temp;
        proc http
            url="&supabase_url./rest/v1/players?select=player_id,overall,mentality_composure,mentality_aggression,mentality_vision,mentality_positioning,mentality_penalties,mentality_interceptions,movement_reactions&limit=&pagesize.&offset=&off"
            method="GET" out=resp;
            headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key";
        run;
        libname j json fileref=resp;
        proc sql noprint; select count(*) into :n from j.root; quit;
        %if &n > 0 %then %do;
            data chunk; set j.root; run;
            proc append base=players data=chunk force; run;
        %end;
        %if &n < &pagesize %then %let more = 0;
        %let page = %eval(&page + 1);
        libname j clear;
    %end;
    proc sql noprint; select count(*) into :nobs from players; quit;
    %put NOTE: pulled &nobs players from Supabase;
%mend;
%pull_players;

/*--- 2. Model: OVERALL ~ psychological profile -----------------------------*/
ods output FitStatistics=fit ParameterEstimates=pe;
proc glmselect data=players;
    model overall = mentality_composure mentality_aggression mentality_vision
                    mentality_positioning mentality_penalties
                    mentality_interceptions movement_reactions
        / selection=stepwise(select=sbc) stb;
    output out=scored predicted=pred residual=resid;
run;

/* correlation-based importance proxy for visualization */
proc corr data=players noprint outp=corrout;
    var mentality_composure mentality_aggression mentality_vision
        mentality_positioning mentality_penalties mentality_interceptions
        movement_reactions;
    with overall;
run;

/*--- 3. Assemble result tables ---------------------------------------------*/
proc sql noprint;
    select n into :n_obs from fit where label1='Observations Read';
quit;

data _rsq;
    set fit;
    if upcase(label2)='R-SQUARE' then call symputx('rsq', cvalue2);
    if upcase(label2)='ADJ R-SQ' then call symputx('adjrsq', cvalue2);
    if upcase(label1)='ROOT MSE' then call symputx('rmse', cvalue1);
run;

/*--- 4. POST results back to Supabase --------------------------------------*/
/* 4a. model_results */
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
            "Content-Type"="application/json"
            "Prefer"="resolution=merge-duplicates";
run;

/* 4b. model_coefficients (one POST with a JSON array) */
data _coef;
    set pe;
    where upcase(parameter) ne 'INTERCEPT';
    length json $400;
    json = cats('{"run_id":"', "&run_id", '","variable":"', parameter,
                '","estimate":', estimate,
                ',"std_error":', stderr,
                ',"t_value":', tvalue,
                ',"p_value":', probt, '}');
run;
proc sql noprint; select json into :coefjson separated by ',' from _coef; quit;
filename body2 temp;
data _null_; file body2; put "[&coefjson]"; run;
proc http url="&supabase_url./rest/v1/model_coefficients" method="POST" in=body2 out=out;
    headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
            "Content-Type"="application/json"
            "Prefer"="resolution=merge-duplicates";
run;

/* 4c. model_predictions (sample to keep payload reasonable) */
data _pred;
    set scored;
    if not missing(pred);
    length json $200;
    json = cats('{"run_id":"', "&run_id", '","player_id":', player_id,
                ',"actual":', overall, ',"predicted":', round(pred,0.01),
                ',"residual":', round(resid,0.01), '}');
run;
proc sql noprint; select json into :predjson separated by ',' from _pred; quit;
filename body3 temp;
data _null_; file body3; put "[&predjson]"; run;
proc http url="&supabase_url./rest/v1/model_predictions" method="POST" in=body3 out=out;
    headers "apikey"="&supabase_key" "Authorization"="Bearer &supabase_key"
            "Content-Type"="application/json"
            "Prefer"="resolution=merge-duplicates";
run;

%put NOTE: Modelling complete. R-square=&rsq  Adj=&adjrsq  RMSE=&rmse  N=&nobs;
