from typing import Optional

from google_cloud_pipeline_components.v1.dataflow import DataflowFlexTemplateJobOp
from kfp import dsl


@dsl.pipeline(
    name="etl-boston-star-p1-flex",
    description="P1.1.1: Boston Raw -> Star fact (snake_case) via Dataflow Flex Template.",
)
def etl_boston_star_p1_pipeline(
    project_id: str,
    region: str,
    template_file_gcs_path: str,
    temp_location: str,
    input_table: str,
    output_table: str,
    service_account: Optional[str] = None,
):
    DataflowFlexTemplateJobOp(
        project=project_id,
        location=region,
        container_spec_gcs_path=template_file_gcs_path,
        job_name="boston-star-p1",
        parameters={
            "project": project_id,
            "region": region,
            "temp_location": temp_location,
            "input_table": input_table,
            "output_table": output_table,
        },
        service_account_email=service_account,
        enable_streaming_engine=False,
    )
