README

## 目的
`onboarding_p1.1.md` に書かれた Boston P1.1.1 の流れ（ローカル DirectRunner → flex テンプレート生成 → Dataflow 実行）を網羅的に追いながら、まっさらな開発者が GCP でデプロイと実行確認まで完了できるように手順と注意点を整理したドキュメントです。

## 前提条件
1. Google Cloud プロジェクト（本例: `yw-playground-dev`）に Artifact Registry（例: `dataflow-sample-yw`）、GCS バケット（例: `gs://dataflow-sample-yw/`）、BigQuery データセット（未作成ならこの手順で作る）が用意されている。
2. `gcloud` CLI がインストールされ、`gcloud config set project yw-playground-dev`、`gcloud config set ai/region us-central1` などの基本設定が済んでいる（`gcloud components install alpha beta` も必要に応じて実行）。
3. Python 環境と依存は `uv` で管理する。まず `python3 -m pip install --user uv` で `uv` CLI を入手し、`uv sync`（`uv sync --frozen`）で `pyproject.toml` に定義されたパッケージをインストール、`uv run` で `python` や `kfp compiler` を起動する流れを守る。`pip install -e .` は不要で、`uv` が自身の `.venv` を作成するため手動で `python3 -m venv` を作る必要はありません。

## WSL2 Ubuntu での `uv` / Docker インストール

WSL2 上の Ubuntu を使うことを前提に、`uv` CLI と Docker を入れる手順をまとめます。

### uv CLI の準備
1. Ubuntu のパッケージを最新にし、Python 3 系と pip を揃える:
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y python3 python3-pip
   ```
2. `uv` をユーザー領域にインストール:
   ```bash
   python3 -m pip install --user uv
   ```
3. `~/.local/bin` を `PATH` に入れてターミナル起動時に自動で利用できるように:
   ```bash
   echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc
   source ~/.bashrc
   ```
4. `uv sync` を実行して依存関係を揃え、`uv run python --version` などで動作確認してください。

### Docker の準備
1. より安定した開発を望むなら、Windows で Docker Desktop をインストールし、設定 > リソース > WSL インテグレーションから対象の Ubuntu ディストリビューションを有効化すると、WSL ターミナルから `docker` コマンドが使えるようになります。
2. Docker Desktop を使わない場合は WSL 側に Docker Engine を入れることも可能です:
   ```bash
   sudo apt install -y docker.io
   sudo usermod -aG docker $USER
   newgrp docker
   sudo service docker start
   ```
3. WSL セッションを再起動するか再ログインして `docker` グループの権限を反映させ、毎回 `sudo service docker start` でデーモンを起動してください。
4. `docker run --rm hello-world` のように実行して、クライアントとデーモンの接続が成功することを確認しましょう。

## 環境準備（BigQuery / GCS / データ）
1. データセットを作成:
   ```bash
   gcloud config set project yw-playground-dev
   bq --location=US mk --dataset yw-playground-dev:raw
   bq --location=US mk --dataset yw-playground-dev:star
   ```
2. UCI ボストン住宅データをローカルに保存し、BigQuery にロード:
   ```bash
   python3 - <<'PY'
   import urllib.request, csv
   url = "https://archive.ics.uci.edu/ml/machine-learning-databases/housing/housing.data"
   lines = [l for l in urllib.request.urlopen(url).read().decode().splitlines() if l.strip()]
   with open("/tmp/boston_housing.csv", "w", encoding="utf-8") as f:
       f.write("CRIM,ZN,INDUS,CHAS,NOX,RM,AGE,DIS,RAD,TAX,PTRATIO,B,LSTAT,MEDV\n")
       f.writelines([",".join(line.split()) + "\n" for line in lines])
   PY
   bq --location=US load \
     --replace --skip_leading_rows=1 \
     yw-playground-dev:raw.boston_raw /tmp/boston_housing.csv \
     CRIM:FLOAT,ZN:FLOAT,INDUS:FLOAT,CHAS:FLOAT,NOX:FLOAT,RM:FLOAT,AGE:FLOAT,DIS:FLOAT,RAD:FLOAT,TAX:FLOAT,PTRATIO:FLOAT,B:FLOAT,LSTAT:FLOAT,MEDV:FLOAT
   ```
3. GCS に出力先（`pipeline_root/`, `temp/`）を押さえ、Dataflow で空ディレクトリを使う:
   ```bash
   gsutil cp /dev/null gs://dataflow-sample-yw/pipeline_root/.keep
   gsutil cp /dev/null gs://dataflow-sample-yw/temp/.keep
   ```

## ローカル検証（オプション）
- `uv run python -m pytest` で既存テスト（今は未実装）を走らせ、Beam モジュールが import できる状態を確認。
- `scripts/run_local_dataflow.sh yw-playground-dev raw.boston_raw star.boston_fact_p1` で DirectRunner を起動し、`boston_star_pipeline.py` の変換が期待どおり動くかを目視確認する。

## flex テンプレートのビルド・再デプロイ
1. `Dockerfile.dataflow` をベースに `boston-star-p1-flex` イメージを Artifact Registry に pushし、metadata を添えて GCS に JSON を出力:
   ```bash
   scripts/build_boston_star_flex_template.sh yw-playground-dev us-west1 dataflow-sample-yw gs://dataflow-sample-yw
   ```
2. `dataflow/star_schema/boston_star_pipeline.py` は Python 3.9 互換になるよう `Optional`/`Iterable` を使うように修正済みで、`RenameColumnsDoFn.process` は `Dict` を `yield` して completion する構造。これがないと type hint ヘルパーが `Dict[<class 'str'>, Any] is not iterable` を吐いて launcher が失敗します。
3. `gs://dataflow-sample-yw/boston_star_p1_flex.json` には新しい image URI、metadata（parameters）も含まれているので、編集後は必ず再生成してください。

## Dataflow flex template の起動
1. `gcloud dataflow flex-template run` を叩き、project/region/temp/入力・出力テーブルを指定:
   ```bash
   gcloud dataflow flex-template run boston-star-p1-flex-$(date +%Y%m%d%H%M%S) \
     --project=yw-playground-dev --region=us-central1 \
     --template-file-gcs-location=gs://dataflow-sample-yw/boston_star_p1_flex.json \
     --parameters=project=yw-playground-dev,region=us-central1,temp_location=gs://dataflow-sample-yw/temp,input_table=yw-playground-dev.raw.boston_raw,output_table=yw-playground-dev.star.boston_fact_p1
   ```
2. ジョブ ID が返ってくるので、`gcloud dataflow jobs describe <JOB_ID> --region=us-central1` あるいは `gcloud dataflow jobs list --status=active` で `JOB_STATE_RUNNING → JOB_STATE_DONE` を確認。
3. 問題が出たら `gcloud logging read 'resource.type="dataflow_step" AND resource.labels.job_id="<JOB_ID>"'` で launcher とテンプレートのログを見て `Template launch failed` や `unsupported operand type(s)` などを解析し、ジョブの再ビルドを検討する。

## 結果の検証と後処理
1. `bq --location=US query --nouse_legacy_sql 'SELECT COUNT(*) FROM `yw-playground-dev.star.boston_fact_p1`'` で行数（本例: 506）が入っていることを確認。
2. 出力テーブルを `bq head yw-playground-dev:star.boston_fact_p1` で見てスキーマが `snake_case` になっていることを目視。
3. 不要になった GCS/BigQuery の一時ファイルやジョブを削除したい場合は `gsutil rm` や `gcloud dataflow jobs cancel <JOB_ID>` を使う。

## Cleanup
このリポジトリ経由で作成したクラウドリソースを一括で削除したいときは、以下の順序で実行するとリソース消し忘れを減らせます。
1. Vertex AI Pipeline Job をキャンセル・削除（`aiplatform.PipelineJob.get('projects/…/pipelineJobs/etl-boston-star-p1-flex-…').cancel()` や `.delete()` を Python から実行し、`gcloud ai-platform` ではなく `aiplatform` SDK 経由で管理する）。既に完了済なら無視。`cleanup/cleanup_resources.py` を `uv run python cleanup/cleanup_resources.py --project=yw-playground-dev --pipeline-job=<resource-name>` として実行すると、Vertex AI → Dataflow → BigQuery → GCS → Artifact Registry →ローカルまで一通り削除できます（`--dry-run` でコマンド一覧のみ出力することも可能）。
2. Dataflow ジョブ（`gcloud dataflow jobs list --region=us-central1` で対象 `JOB_ID` を特定し、`gcloud dataflow jobs cancel <JOB_ID> --region=us-central1`）。
3. BigQuery のテーブル／データセットを削除：
   ```bash
   bq --location=US rm -f -t yw-playground-dev:star.boston_fact_p1
   bq --location=US rm -f -t yw-playground-dev:raw.boston_raw
   bq --location=US rm -r -f yw-playground-dev:raw
   bq --location=US rm -r -f yw-playground-dev:star
   ```
4. GCS 上のテンプレート/パイプライン出力/一時オブジェクトを消す（`gsutil rm -r gs://dataflow-sample-yw/*` など、テンプレート JSON・`pipeline_root/`・`temp/`・`dataflow-staging-*` に注意）。
5. Artifact Registry の Docker イメージ削除：`gcloud artifacts docker images delete us-west1-docker.pkg.dev/yw-playground-dev/dataflow-sample-yw/boston-star-p1-flex --delete-tags --quiet`。
6. `.venv` やその他ローカル生成物（`uv` の `.venv`、`__pycache__`）は `rm -rf .venv __pycache__` でクリーンアップ。

この順番で実行すれば、Dataflow/Vertex AI から始まり BigQuery・GCS・Artifact Registry・ローカルの順にリソースを片付けられます。必要に応じて上記コマンドをスクリプト化して、定期的なクリーンアップを自動化しておくと安全です。

### cleanup/cleanup_resources.py の使い方
`cleanup/cleanup_resources.py` を `uv run python cleanup/cleanup_resources.py --project=yw-playground-dev --pipeline-job=<resource-name>` で起動すると、上記の6ステップを自動的に実行します。あらかじめ `uv sync` して依存を揃えるか、`.venv/bin/python cleanup/cleanup_resources.py …` で実行してください。`--dry-run` を付けると実際の削除コマンドを表示するだけになります。

### 削除の確認方法
1. `gcloud dataflow jobs list --region=us-central1` で `boston-star-p1` 系のジョブが `Done`/`Cancelled` のみ（`Running`/`Queued` が無い）であることを確認。
2. `bq --location=US ls yw-playground-dev:raw` / `yw-playground-dev:star` が `Not found`（データセット消去）であること。
3. `gsutil ls gs://dataflow-sample-yw/` および `gsutil ls gs://dataflow-staging-us-central1-*` で空、または該当パスが存在しないこと。
4. `gcloud artifacts docker images list us-west1-docker.pkg.dev/yw-playground-dev/dataflow-sample-yw` で該当イメージが返らないこと。

## Onboarding (p1.1 の流れ)
クラシックな Boston P1.1.1 の onboarding フローに沿って、以下のステップを補完しています。1〜4 を順番にこなすことで、まっさらな環境から BigQuery テーブルの準備、flex テンプレートのビルド＆ GCS 配備、Vertex AI/直接実行での Dataflow 送信までをカバーできます。
1. ローカル DirectRunner の実行（`scripts/run_local_dataflow.sh PROJECT raw.boston_raw star.boston_fact_p1`）で `dataflow/star_schema/boston_star_pipeline.py` の変換を検証。
2. flex テンプレートのビルドと Artifact Registry/GCS へのデプロイ（`scripts/build_boston_star_flex_template.sh ...`）。
3. Vertex AI Pipeline からプロダクション運用に載せる層として `scripts/submit_etl_boston_star_p1_pipeline.sh ...` を使う（`pipelines/etl_boston_star_p1_pipeline.py` 内 `DataflowFlexTemplateJobOp` がエントリ）。
4. 必要に応じて `gcloud dataflow flex-template run ...` で直接ジョブを起動し、`bq` で出力を確認。
README にはこれらのコマンドの意味、ログの追い方、失敗時の解析パターン（例: type hint エラー）を補足し、`config/pipelines/boston_star_flex_template_metadata.json` の更新 → `scripts/build_boston_star_flex_template.sh` 実行という再デプロイのループも書き残しています。

## 今後の整備候補
1. `.env.example` や README にデフォルト値を列挙（project/region/temp/input/output）し、環境の再現性を高める。
2. pytest で `dataflow/star_schema/` の変換ロジックを直接検証し、`scripts/run_local_dataflow.sh` で DirectRunner による smoke test を組み込む。
3. `scripts/submit_etl_boston_star_p1_pipeline.sh` を Vertex AI Pipeline で使う場合、KFP の `DataflowFlexTemplateJobOp` に渡すパラメータを README/AGENTS に明記して、実行手順との整合性を保つ。
