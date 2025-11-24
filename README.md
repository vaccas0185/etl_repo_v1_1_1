README

## 目的
`onboarding_p1.1.md` に書かれた Boston P1.1.1 の流れ（ローカル DirectRunner → flex テンプレート生成 → Dataflow 実行）を網羅的に追いながら、まっさらな開発者が GCP でデプロイと実行確認まで完了できるように手順と注意点を整理したドキュメントです。

## ディレクトリ構成

リポジトリ内の主要ディレクトリとファイルをツリー形式でまとめています（コメント付き）。

```text
.
├── dataflow/                      # Beam パイプラインと変換ロジック
│   └── star_schema/               # Boston 用 Star スキーマ実装（boston_star_pipeline.py）
├── pipelines/                     # Vertex AI などから起動するパイプライン定義（etl_boston_star_p1_pipeline.py）
├── config/                        # テンプレート／デプロイ用メタデータ
│   └── pipelines/
│       └── boston_star_flex_template_metadata.json  # Flex テンプレートのメタ情報
├── scripts/                       # ビルド・ローカル実行・送信・クリーンアップ用スクリプト
│   ├── build_boston_star_flex_template.sh
│   ├── run_local_dataflow.sh
│   ├── run_flex_template.sh       # Flex テンプレートを gcloud 経由で起動
│   ├── submit_etl_boston_star_p1_pipeline.sh
│   └── cleanup.sh                 # Dataflow/Vertex AI/BigQuery/GCS/Artifact Registry/ローカルの削除
├── docker/                        # Dataflow 実行イメージ・開発用イメージの Dockerfile
│   ├── Dockerfile.dataflow
│   └── Dockerfile.dev
├── pyproject.toml                 # Python プロジェクト定義・依存
├── README.md                      # このドキュメント
└── AGENTS.md                      # リポジトリ運用ガイド
```

## 前提条件
1. Google Cloud プロジェクト ID（例: `yw-playground-dev`）を決めておく。
2. `gcloud` CLI がインストールされ、ローカルで認証済みであること（`gcloud auth application-default login` など）。
3. Python 環境と依存は `uv` で管理する。まず `python3 -m pip install --user uv` で `uv` CLI を入手し、`uv sync`（`uv sync --frozen`）で `pyproject.toml` に定義されたパッケージをインストール、`uv run` で `python` や `kfp compiler` を起動する流れを守る。`pip install -e .` は不要で、`uv` が自身の `.venv` を作成するため手動で `python3 -m venv` を作る必要はありません。

## WSL2 Ubuntu での `uv` / Docker インストール

WSL2 上の Ubuntu を前提に、公式インストーラを使った `uv` CLI と Docker のセットアップ手順をまとめます。

### uv CLI の準備
1. パッケージ更新と基本ツール（`curl` はインストーラ取得に必須）をインストール:
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y python3 python3-pip curl ca-certificates
   ```
2. 公式インストーラで `uv` を導入:
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
   ※ WSL/Ubuntu ではデフォルトで `~/.local/bin` に配置されます。シェル再読み込み後に `uv --version` で確認してください。
3. `PATH` に `~/.local/bin` が入っていない場合のみ追記:
   ```bash
   grep -q "$HOME/.local/bin" <<< "$PATH" || echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc
   source ~/.bashrc
   ```
4. 動作確認:
   ```bash
   uv --version
   uv run python --version
   ```

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
`scripts/setup.sh` 1 本で必要リソースを作成します。デフォルトでは以下を生成します:

- Artifact Registry: `dataflow-<PROJECT_ID>` （リージョン: `us-central1`）
- GCS バケット: `gs://dataflow-<PROJECT_ID>/` （`pipeline_root/`, `temp/` を作成）
- BigQuery データセット: `<PROJECT_ID>:raw`, `<PROJECT_ID>:star`
- サンプルテーブル: `<PROJECT_ID>.raw.boston_raw`
- Dataflow 実行用サービスアカウント: `etl-dataflow-runner@<PROJECT_ID>.iam.gserviceaccount.com`

実行例:
```bash
scripts/setup.sh --project yw-playground-dev
# リージョンやリポジトリ名を変えたい場合:
# scripts/setup.sh --project yw-playground-dev --dataflow-region us-east1 --artifact-region us-east1 --artifact-repo my-repo --bucket my-bucket --bucket-location US --dataset-location US
```

## ローカル検証（オプション）
- 目的: 本番と同じ Beam 変換をローカルの DirectRunner で動かし、BigQuery 入力→変換→BigQuery 出力が通るかを手元で確認します。
- 実行: `scripts/run_local_dataflow.sh --project <PROJECT_ID>`  
  - 何をしているか（概略）  
    1) `docker/Dockerfile.dev` からローカル検証用イメージ `etl-dev` をビルド（無ければ自動ビルド、Storage Write API 用に JRE を内包）。既に作成済みの `etl-dev` がある場合は再ビルドを推奨（`docker rmi etl-dev` など）。  
    2) ホストのソースツリーを `/app` にマウントし、`uv sync` で依存をセットアップ。  
    3) `dataflow/star_schema/boston_star_pipeline.py` を DirectRunner で実行し、BigQuery Storage API (DirectRead) で読み込み→カラム名を snake_case にリネーム→BigQuery へ書き込み（Storage Write API を使用し、GCS ステージングなしのバッチ挿入）。  
    4) gcloud ADC をホストの `~/.config/gcloud` から読み込み、`GOOGLE_CLOUD_PROJECT` をコンテナ内に渡して API 認証を行う。  
  - 入力/出力テーブルはデフォルトで `<PROJECT>.raw.boston_raw` / `<PROJECT>.star.boston_fact_p1`、一時 GCS は `gs://dataflow-<PROJECT>/temp`。必要に応じて `--input` / `--output` / `--temp-location` で上書きできます。
  - 読み込み方式を DirectRead にしたことで、一時エクスポートのクリーンアップに伴う `No iterator is returned by the process method...` WARNING は発生しません。
- 結果確認: `bq head <PROJECT>:star.boston_fact_p1` で出力テーブルの先頭行を確認し、変換が反映されていることを目視してください。

## flex テンプレートのビルド・再デプロイ
- 目的: Dataflow Flex Template 用の実行イメージを Artifact Registry にビルド＆pushし、テンプレート JSON を GCS に配置して再デプロイできる状態にする。
- 実行: `scripts/build_boston_star_flex_template.sh <PROJECT_ID>` またはロングオプションで `scripts/build_boston_star_flex_template.sh --project <PROJECT_ID> [--region ... --artifact-repo ... --template-gcs-path ...]`  
  - デフォルト設定: REGION=`us-central1`、ARTIFACT_REPO=`dataflow-<PROJECT_ID>`、TEMPLATE_PATH=`gs://dataflow-<PROJECT_ID>/boston_star_p1_flex.json`。必要に応じてフラグや位置引数で上書き可能。  
  - 何をしているか（概略）  
    1) `docker/Dockerfile.dataflow` から `boston-star-p1-flex` イメージをビルド。  
    2) イメージを Artifact Registry (`<REGION>-docker.pkg.dev/<PROJECT_ID>/<ARTIFACT_REPO>/...`) に push。  
    3) `config/pipelines/boston_star_flex_template_metadata.json` を用いて Flex Template JSON を生成し、GCS (`TEMPLATE_PATH`) に保存。  
  - リージョンは Artifact Registry / Dataflow / AI Platform を揃える運用を想定（特別な理由がなければ `us-central1` のままで可）。
- 再生成が必要なタイミング: パイプラインコード変更、依存更新、Dockerfile.dataflow 更新、テンプレート metadata 更新時は必ず上記スクリプトを再実行し、GCS 上の JSON を更新する。

## Dataflow flex template の起動
- 実行: `scripts/run_flex_template.sh <PROJECT_ID>`（プロジェクト ID だけ指定すれば他はデフォルトを使用）  
  - デフォルト: REGION=`us-central1`、TEMPLATE=`gs://dataflow-<PROJECT_ID>/boston_star_p1_flex.json`、TEMP=`gs://dataflow-<PROJECT_ID>/temp`、INPUT=`<PROJECT_ID>.raw.boston_raw`、OUTPUT=`<PROJECT_ID>.star.boston_fact_p1`、SA=`etl-dataflow-runner@<PROJECT_ID>.iam.gserviceaccount.com`。必要に応じて `--region` / `--template` / `--temp-location` / `--input` / `--output` / `--service-account` / `--job-name` で上書き可。
  - 例:
    ```bash
    scripts/run_flex_template.sh yw-playground-dev
    ```
- モニタリング: `gcloud dataflow jobs describe <JOB_ID> --region=<REGION>` や `gcloud dataflow jobs list --status=active --region=<REGION>` で進捗確認。
- トラブルシュート: 問題が出た場合は `gcloud logging read 'resource.type="dataflow_step" AND resource.labels.job_id="<JOB_ID>"' --project <PROJECT_ID>` でテンプレート実行時のログを確認し、必要なら再ビルド/再実行。

## 結果の検証と後処理
1. `bq --location=US query --nouse_legacy_sql 'SELECT COUNT(*) FROM `yw-playground-dev.star.boston_fact_p1`'` で行数（本例: 506）が入っていることを確認。
2. 出力テーブルを `bq head yw-playground-dev:star.boston_fact_p1` で見てスキーマが `snake_case` になっていることを目視（bq CLI は `project:dataset.table` 形式も可）。
3. 不要になった GCS/BigQuery の一時ファイルやジョブを削除したい場合は `gsutil rm` や `gcloud dataflow jobs cancel <JOB_ID>` を使う。

## Cleanup
このリポジトリ経由で作成したクラウドリソースを一括で削除したいときは、以下の順序で実行するとリソース消し忘れを減らせます。
1. Vertex AI Pipeline Job をキャンセル・削除（`aiplatform.PipelineJob.get('projects/…/pipelineJobs/etl-boston-star-p1-flex-…').cancel()` や `.delete()` を Python から実行し、`gcloud ai-platform` ではなく `aiplatform` SDK 経由で管理する）。既に完了済なら無視。手早くまとめて消したい場合は `scripts/cleanup.sh --project=yw-playground-dev --pipeline-job=<resource-name>` を使うと、Vertex AI → Dataflow → BigQuery → GCS → Artifact Registry →ローカルまで一通り削除できます（`--dry-run` でコマンド一覧のみ出力することも可能）。
2. Dataflow ジョブ（`gcloud dataflow jobs list --region=us-central1` で対象 `JOB_ID` を特定し、`gcloud dataflow jobs cancel <JOB_ID> --region=us-central1`）。
3. BigQuery のテーブル／データセットを削除：
   ```bash
   bq --location=US rm -f -t yw-playground-dev:star.boston_fact_p1
   bq --location=US rm -f -t yw-playground-dev:raw.boston_raw
   bq --location=US rm -r -f yw-playground-dev:raw
   bq --location=US rm -r -f yw-playground-dev:star
   ```
4. GCS 上のテンプレート/パイプライン出力/一時オブジェクトを消す（`gsutil rm -r gs://dataflow-yw-playground-dev/*` など、テンプレート JSON・`pipeline_root/`・`temp/`・`dataflow-staging-*` に注意）。
5. Artifact Registry の Docker イメージ削除：`gcloud artifacts docker images delete us-central1-docker.pkg.dev/yw-playground-dev/dataflow-yw-playground-dev/boston-star-p1-flex --delete-tags --quiet`。
6. `.venv` やその他ローカル生成物（`uv` の `.venv`、`__pycache__`）は `rm -rf .venv __pycache__` でクリーンアップ。

この順番で実行すれば、Dataflow/Vertex AI から始まり BigQuery・GCS・Artifact Registry・ローカルの順にリソースを片付けられます。必要に応じて上記コマンドをスクリプト化して、定期的なクリーンアップを自動化しておくと安全です。

上記 1〜6 を一括で実行したい場合は、bash 版 `scripts/cleanup.sh` を使ってください。
例: `scripts/cleanup.sh --project=yw-playground-dev --pipeline-job=<resource-name>`
オプション:
- `--dry-run`: 実行せずコマンドのみ表示
- `--keep-bucket`, `--keep-artifact-repo`: バケット／Artifact Registry リポジトリを残したい場合に指定

### 削除の確認方法
1. `gcloud dataflow jobs list --region=us-central1` で `boston-star-p1` 系のジョブが `Done`/`Cancelled` のみ（`Running`/`Queued` が無い）であることを確認。
2. `bq --location=US ls yw-playground-dev:raw` / `yw-playground-dev:star` が `Not found`（データセット消去）であること。
3. `gsutil ls gs://dataflow-yw-playground-dev/` および `gsutil ls gs://dataflow-staging-us-central1-*` で空、または該当パスが存在しないこと。
4. `gcloud artifacts docker images list us-central1-docker.pkg.dev/yw-playground-dev/dataflow-yw-playground-dev` で該当イメージが返らないこと。

## Onboarding (p1.1 の流れ)
クラシックな Boston P1.1.1 の onboarding フローに沿って、以下のステップを補完しています。1〜4 を順番にこなすことで、まっさらな環境から BigQuery テーブルの準備、flex テンプレートのビルド＆ GCS 配備、Vertex AI/直接実行での Dataflow 送信までをカバーできます。
1. ローカル DirectRunner の実行（`scripts/run_local_dataflow.sh PROJECT`。必要なら第2/第3引数でテーブルを上書き）で `dataflow/star_schema/boston_star_pipeline.py` の変換を検証。
2. flex テンプレートのビルドと Artifact Registry/GCS へのデプロイ（`scripts/build_boston_star_flex_template.sh ...`）。
3. Vertex AI Pipeline からプロダクション運用に載せる層として `scripts/submit_etl_boston_star_p1_pipeline.sh ...` を使う（`pipelines/etl_boston_star_p1_pipeline.py` 内 `DataflowFlexTemplateJobOp` がエントリ）。
4. 必要に応じて `gcloud dataflow flex-template run ...` で直接ジョブを起動し、`bq` で出力を確認。
README にはこれらのコマンドの意味、ログの追い方、失敗時の解析パターン（例: type hint エラー）を補足し、`config/pipelines/boston_star_flex_template_metadata.json` の更新 → `scripts/build_boston_star_flex_template.sh` 実行という再デプロイのループも書き残しています。

## 今後の整備候補
1. `.env.example` や README にデフォルト値を列挙（project/region/temp/input/output）し、環境の再現性を高める。
2. pytest で `dataflow/star_schema/` の変換ロジックを直接検証し、`scripts/run_local_dataflow.sh` で DirectRunner による smoke test を組み込む。
3. `scripts/submit_etl_boston_star_p1_pipeline.sh` を Vertex AI Pipeline で使う場合、KFP の `DataflowFlexTemplateJobOp` に渡すパラメータを README/AGENTS に明記して、実行手順との整合性を保つ。
