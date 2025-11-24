from typing import Optional

from google_cloud_pipeline_components.v1.dataflow import DataflowFlexTemplateJobOp
from kfp import dsl


@dsl.pipeline(
    name="etl-boston-star-p1-flex",
    description="P1.1.1: Boston の Raw データを Dataflow Flex Template で Star スキーマ（snake_case）に変換するパイプライン。",
)
def etl_boston_star_p1_pipeline(
    project_id: str,
    region: str,
    template_file_gcs_path: str,
    temp_location: str,
    input_table: str,
    output_table: str,
    service_account: Optional[str] = None,
    job_name: Optional[str] = None,
):
    resolved_job_name = job_name or "boston-star-p1"
    DataflowFlexTemplateJobOp(
        project=project_id,
        location=region,
        container_spec_gcs_path=template_file_gcs_path,
        job_name=resolved_job_name,
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
