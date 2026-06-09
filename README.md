# Football Ability from a Psychological Profile

Can a footballer's **psychological / mentality profile** predict their **overall ability**?
This project builds an end-to-end pipeline to find out and publishes the story on GitHub Pages.

**Pipeline:** raw player data → cleaned in Python → **Supabase** (Postgres) → modelled in
**SAS Viya** (`overall` = explained variable) → results written back to Supabase →
visualized on a public GitHub Pages site.

🔗 **Live site:** _enable GitHub Pages (Settings → Pages → branch `main`, folder `/docs`)_

## Data

Modelling base: the **FIFA 22 complete player dataset** (~19k players). The `overall`
ability rating is the target; the predictors are *mentality* attributes that proxy a
psychological profile: composure, aggression, vision, positioning, penalties,
interceptions and reactions.

> **Caveat:** these are scout-rated game attributes, not a validated psychometric test.
> The site frames the results honestly and sets them against the real academic literature
> (Big Five / mental-toughness studies of athletes).

## Repo layout

| Path | What |
|------|------|
| `sql/schema.sql` | Supabase tables (players + model result tables, with public-read RLS) |
| `scripts/download_data.py` | Fetch the raw FIFA CSV |
| `scripts/run_schema.py` | Apply the schema to Supabase |
| `scripts/load_to_supabase.py` | Clean + load players into Supabase |
| `sas/model.sas` | SAS Viya: pull from Supabase, model, POST results back |
| `docs/` | The GitHub Pages site (reads results live from Supabase) |

## Setup

```bash
cp .env.example .env          # fill in Supabase credentials
cp docs/config.example.js docs/config.js   # fill in URL + anon key

pip install -r scripts/requirements.txt
python scripts/download_data.py
python scripts/run_schema.py
python scripts/load_to_supabase.py
# then run sas/model.sas on SAS Viya (inject supabase_url + service key macros)
```

Secrets live only in `.env` / `docs/config.js`, both git-ignored. The site uses the
Supabase **anon** key (read-only via RLS), which is safe to publish.

## License

Code: MIT. Player data © its respective sources, used here for research/education.
