import argparse
import logging
from typing import Dict, Any, Tuple, List, Optional, Iterable

import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, SetupOptions

COLUMN_MAPPING = {
    "CRIM": "crim",
    "ZN": "zn",
    "INDUS": "indus",
    "CHAS": "chas",
    "NOX": "nox",
    "RM": "rm",
    "AGE": "age",
    "DIS": "dis",
    "RAD": "rad",
    "TAX": "tax",
    "PTRATIO": "ptratio",
    "B": "b",
    "LSTAT": "lstat",
    "MEDV": "medv",
}


class RenameColumnsDoFn(beam.DoFn):
    def process(self, element: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
        renamed = {}
        for src, dst in COLUMN_MAPPING.items():
            if src not in element:
                raise ValueError(f"Expected column '{src}' not found in row: {element}")
            renamed[dst] = element[src]
        yield renamed


def run(
    project: str,
    input_table: str,
    output_table: str,
    region: Optional[str] = None,
    temp_location: Optional[str] = None,
    runner: Optional[str] = None,
    save_main_session: bool = True,
    pipeline_args: Optional[List[str]] = None,
) -> None:
    # Beam 内部 DoFn から出る「No iterator is returned...」警告を抑制する
    logging.getLogger("apache_beam.transforms.core").setLevel(logging.ERROR)

    def normalize_table(table: str) -> str:
        # Beam の BQ I/O は project.dataset.table 形式を要求するため、
        # 誤って project:dataset.table で渡された場合はドットに揃える。
        return table.replace(":", ".", 1)

    input_table = normalize_table(input_table)
    output_table = normalize_table(output_table)

    extra_options: Dict[str, Any] = {"project": project}

    if region:
        extra_options["region"] = region
    if temp_location:
        extra_options["temp_location"] = temp_location
    if runner:
        extra_options["runner"] = runner

    pipeline_args = pipeline_args or []
    options = PipelineOptions(pipeline_args, **extra_options)
    options.view_as(SetupOptions).save_main_session = save_main_session

    query = f"SELECT * FROM `{input_table}`"

    with beam.Pipeline(options=options) as p:
        (
            p
            | "ReadFromBigQuery"
            >> beam.io.ReadFromBigQuery(
                query=query,
                use_standard_sql=True,
                method=beam.io.ReadFromBigQuery.Method.DIRECT_READ,
            )
            | "RenameColumns" >> beam.ParDo(RenameColumnsDoFn())
            | "WriteToBigQuery"
            >> beam.io.WriteToBigQuery(
                table=output_table,
                schema={
                    "fields": [
                        {"name": "crim", "type": "FLOAT"},
                        {"name": "zn", "type": "FLOAT"},
                        {"name": "indus", "type": "FLOAT"},
                        {"name": "chas", "type": "FLOAT"},
                        {"name": "nox", "type": "FLOAT"},
                        {"name": "rm", "type": "FLOAT"},
                        {"name": "age", "type": "FLOAT"},
                        {"name": "dis", "type": "FLOAT"},
                        {"name": "rad", "type": "FLOAT"},
                        {"name": "tax", "type": "FLOAT"},
                        {"name": "ptratio", "type": "FLOAT"},
                        {"name": "b", "type": "FLOAT"},
                        {"name": "lstat", "type": "FLOAT"},
                        {"name": "medv", "type": "FLOAT"},
                    ]
                },
                write_disposition=beam.io.BigQueryDisposition.WRITE_TRUNCATE,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED,
                # Storage Write API を使い、GCS ステージングなしでバッチ挿入する
                method=beam.io.WriteToBigQuery.Method.STORAGE_WRITE_API,
            )
        )


def parse_args(argv: Optional[List[str]] = None) -> Tuple[argparse.Namespace, List[str]]:
    parser = argparse.ArgumentParser()

    parser.add_argument("--project", required=True)
    parser.add_argument("--input_table", required=True)
    parser.add_argument("--output_table", required=True)
    parser.add_argument("--region", default=None)
    parser.add_argument("--temp_location", default=None)
    parser.add_argument("--runner", default=None)

    known_args, pipeline_args = parser.parse_known_args(argv)
    return known_args, pipeline_args


def main(argv: Optional[List[str]] = None) -> None:
    known_args, pipeline_args = parse_args(argv)
    run(
        project=known_args.project,
        input_table=known_args.input_table,
        output_table=known_args.output_table,
        region=known_args.region,
        temp_location=known_args.temp_location,
        runner=known_args.runner,
        pipeline_args=pipeline_args,
    )


if __name__ == "__main__":
    main()
