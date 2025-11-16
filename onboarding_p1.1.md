# onboarding_p1.1.md

This repository contains ETL pipelines for Boston housing P1.1.1.

Please refer to the ChatGPT session for the full narrative description.
Core steps:
- Build dev image: `docker build -f docker/Dockerfile.dev -t etl-dev .`
- Run local DirectRunner: `scripts/run_local_dataflow.sh PROJECT raw.boston_raw star.boston_fact_p1`
- Build Flex Template: `scripts/build_boston_star_flex_template.sh ...`
- Submit Vertex AI Pipeline: `scripts/submit_etl_boston_star_p1_pipeline.sh ...`
