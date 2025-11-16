# Repository Guidelines

## Project Structure & Module Organization
`pipelines/` houses lightweight job definitions (see `etl_boston_star_p1_pipeline.py` for the entry point), while `dataflow/star_schema/` contains the Beam and schema logic that the jobs orchestrate. Metadata for deployed templates lives under `config/pipelines/`, Docker assets for local and flex-template builds under `docker/`, and shell wrappers (`scripts/`) package recurring operations such as building, running, or submitting pipelines. `pyproject.toml` defines the Python project metadata and dependencies.

## Build, Test, and Development Commands
- `python -m pip install -e .` installs the project plus dataflow and GCP dependencies so scripts can run locally.
- `python -m pytest` runs all tests once they exist; `pytest --cov` enables coverage reporting against whichever modules are exercised.
- `scripts/build_boston_star_flex_template.sh` produces the Beam flex template artifact that eventually lives in GCS.
- `scripts/run_local_dataflow.sh` launches the flex template against a local runner; use it for debugging before deployment.
- `scripts/submit_etl_boston_star_p1_pipeline.sh` submits the built template to the target GCP project and region.

## Coding Style & Naming Conventions
Use four spaces for indentation and keep module-level functions in `snake_case`; pipeline factories (like `create_pipeline`) should clearly return Beam transforms. Prefer descriptive variable names (`table_spec`, `run_config`) and keep Beam transforms encapsulated in `dataflow/star_schema/`. Type annotations are encouraged for public helpers, and docstrings should explain non-obvious behavior. Apply `black`-style formatting even though the repo does not yet auto-format.

## Testing Guidelines
`pytest` is the primary test runner; use `tests/test_*.py` as the naming pattern and mirror that layout as test files grow. Focus tests on verifying transforms, metadata parsing, and script wrappers. Running `pytest --cov=dataflow` ensures coverage reports target the Beam code.

## Commit & Pull Request Guidelines
History currently contains a single `init` commit, so continue with that concise, imperative style (`Add flex-template metadata`). Pull requests should include a short summary, link any relevant issue or deployment ticket, and note if a template rebuild or dataset refresh is required. Attach screenshots or pipeline run logs only when visual changes occur.

## Configuration & Deployment Notes
Keep per-pipeline metadata in `config/pipelines/boston_star_flex_template_metadata.json`; update it before rebuilding templates. Credentials and secrets should stay out of the repo—point shell wrappers at protected environment variables or mounted service accounts instead of hard-coded values.
