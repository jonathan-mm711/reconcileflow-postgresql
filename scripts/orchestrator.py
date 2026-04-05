from pathlib import Path
from datetime import datetime, timedelta
import re
import pandas as pd
from sqlalchemy import text, create_engine
from dotenv import load_dotenv
import os

load_dotenv()

DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_NAME = os.getenv("DB_NAME")

required_vars = ["DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME"]

for var in required_vars:
    if not os.getenv(var):
        raise ValueError(f"Missing environment variable: {var}")

engine = create_engine(
    f"postgresql+psycopg2://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)



BASE_DIR = Path(__file__).resolve().parent.parent

# <<<<<<<<<<<<< INPUT >>>>>>>>>>>>>>>
SCHEMA = BASE_DIR / "sql" / "schema.sql"

SQL_SCRIPTS = [
    BASE_DIR / "sql" / "incoming_eft.sql",
    BASE_DIR / "sql" / "incoming_payments.sql",
    BASE_DIR / "sql" / "internal_payments.sql",
    BASE_DIR / "sql" / "outgoing_eft.sql",
]

START_DATE = "2025-10-01"
END_DATE = "2025-10-31"

CREATE_SCHEMA = True
LOAD_RAW_TO_POSTGRES = True
RUN_RECONCILIATIONS = True
EXPORT_REPORTS = True

# <<<<<<<<<<<<< INPUT >>>>>>>>>>>>>>>

EBRA_DIR = BASE_DIR / "data" / "EBRA"
RDAP_DIR = BASE_DIR / "data" / "RDAP"
SCTEF_DIR = BASE_DIR / "data" / "SCTEF"
OUTPUT_DIR = BASE_DIR / "output"



def write_runtime_params(run_date: str):
    file_path = BASE_DIR / "scripts" / "runtime_params.py"

    content = f'''reconciliation_date = "{run_date}"
ebra_dir = r"{EBRA_DIR}"
rdap_dir = r"{RDAP_DIR}"
sctef_dir = r"{SCTEF_DIR}"
output_dir = r"{OUTPUT_DIR}"
'''

    file_path.write_text(content, encoding="utf-8")


def consolidate_detail_files(output_folder: Path):
    files = [
        f for f in output_folder.iterdir()
        if (
            f.is_file()
            and f.suffix.lower() == ".csv"
            and "DETAIL" in f.name.upper()
            and not f.name.upper().startswith("DETAIL_ALL")
            and not re.match(r"DETAIL_\d{4}-\d{2}\.csv$", f.name.upper())
        )
    ]

    if not files:
        print("No DETAIL files found for consolidation.")
        return

    monthly_groups = {}
    all_frames = []

    for file in files:
        try:
            df = pd.read_csv(file, sep=";", dtype=str, encoding="utf-8")
        except Exception as e:
            print(f"Could not read {file.name}: {e}")
            continue

        all_frames.append(df)

        match = re.search(r"(\d{4}-\d{2})-\d{2}", file.name)
        if match:
            month = match.group(1)
            monthly_groups.setdefault(month, []).append(df)

    for month, dfs in monthly_groups.items():
        df_month = pd.concat(dfs, ignore_index=True)
        output_path = output_folder / f"DETAIL_{month}.csv"
        df_month.to_csv(output_path, sep=";", index=False, encoding="utf-8")
        print(f"Monthly file created: {output_path.name}")

    if all_frames:
        df_total = pd.concat(all_frames, ignore_index=True)
        output_path = output_folder / "DETAIL_ALL.csv"
        df_total.to_csv(output_path, sep=";", index=False, encoding="utf-8")
        print(f"Global file created: {output_path.name}")

def create_schema(sql_script: Path):
    query =  sql_script.read_text(encoding="utf-8")

    with engine.begin() as conn:
        conn.execute(text(query))
    
    print("Tables created successfully.")

def load_raw_to_postgres(reconciliation_date, ebra_dir, sctef_dir, rdap_dir):

    # --- EBRA / EBRV ---
    ebra_widths = [12, 12, 12, 3, 20, 20, 17, 4, 4, 12, 12, 18, 4, 8]
    ebra_columns = [
        "TRACE_ID", "AMOUNT", "TIMESTAMP", "RESPONSE_CODE",
        "ORIGIN_ACCOUNT", "DESTINATION_ACCOUNT", "REFERENCE",
        "ORIGIN_BANK", "DESTINATION_BANK",
        "ORIGIN_RUT", "DESTINATION_RUT",
        "ORIGIN_NAME", "MESSAGE_TYPE", "REFERENCE_2"
    ]

    ebra_cycle_1 = pd.read_fwf(f"{ebra_dir}\\EBRA_C1_{reconciliation_date}.txt",widths=ebra_widths,names=ebra_columns,dtype=str,encoding="utf-8")

    ebra_cycle_2 = pd.read_fwf(f"{ebra_dir}\\EBRA_C2_{reconciliation_date}.txt",widths=ebra_widths,names=ebra_columns,dtype=str,encoding="utf-8")

    ebrv_cycle_1 = pd.read_fwf(f"{ebra_dir}\\EBRV_C1_{reconciliation_date}.txt",widths=ebra_widths,names=ebra_columns,dtype=str,encoding="utf-8")

    ebrv_cycle_2 = pd.read_fwf(f"{ebra_dir}\\EBRV_C2_{reconciliation_date}.txt",widths=ebra_widths,names=ebra_columns,dtype=str,encoding="utf-8")


    ebra = pd.concat([ebra_cycle_1, ebra_cycle_2])
    ebrv = pd.concat([ebrv_cycle_1, ebrv_cycle_2])

    # --- SCTEF ---
    sctef = pd.read_csv(f"{sctef_dir}\\SCTEF_{reconciliation_date}.csv",sep=";",dtype=str,encoding="utf-8")

    rdap_widths = [4, 8, 6, 8, 20, 15, 8, 3]
    rdap_columns = [
        "MERCHANT_CODE", "TRANSACTION_DATE",
        "TRANSACTION_TIME", "SEQUENCE",
        "RUT", "AMOUNT",
        "ACCOUNTING_DATE", "RESPONSE_CODE"
    ]

    # --- RDAP ---
    rdap_1172 = pd.read_fwf(f"{rdap_dir}\\RDAP1172_{reconciliation_date}.txt",widths=rdap_widths,names=rdap_columns,dtype=str,encoding="utf-8")

    rdap_1178 = pd.read_fwf(f"{rdap_dir}\\RDAP1178_{reconciliation_date}.txt",widths=rdap_widths,names=rdap_columns,dtype=str,encoding="utf-8")


    # rename
    sctef.rename(columns={
        "TXN AMT": "TXN_AMT",
        "PURGE DATE": "PURGE_DATE",
    }, inplace=True)

    # lower
    for df in [ebra, ebrv, sctef, rdap_1172, rdap_1178]:
        df.columns = df.columns.str.lower()
        df["reconciliation_date"] = reconciliation_date

    # load
    with engine.begin() as conn:
        conn.execute(text("DELETE FROM ebra_raw WHERE reconciliation_date = :d"), {"d": reconciliation_date})
        conn.execute(text("DELETE FROM ebrv_raw WHERE reconciliation_date = :d"), {"d": reconciliation_date})
        conn.execute(text("DELETE FROM sctef_raw WHERE reconciliation_date = :d"), {"d": reconciliation_date})
        conn.execute(text("DELETE FROM rdap_1172_raw WHERE reconciliation_date = :d"), {"d": reconciliation_date})
        conn.execute(text("DELETE FROM rdap_1178_raw WHERE reconciliation_date = :d"), {"d": reconciliation_date})

    ebra.to_sql("ebra_raw", con=engine, if_exists="append", index=False)
    ebrv.to_sql("ebrv_raw", con=engine, if_exists="append", index=False)
    sctef.to_sql("sctef_raw", con=engine, if_exists="append", index=False)
    rdap_1172.to_sql("rdap_1172_raw", con=engine, if_exists="append", index=False)
    rdap_1178.to_sql("rdap_1178_raw", con=engine, if_exists="append", index=False)

    print(f"Raw data loaded for {reconciliation_date}")

def run_reconciliations(sql_scripts: list[Path], run_date: str):
    with engine.begin() as conn:
        conn.execute(
            text("DELETE FROM reconciliation_detail WHERE reconciliation_date = :d"),
            {"d": run_date}
        )
        conn.execute(
            text("DELETE FROM reconciliation_summary WHERE reconciliation_date = :d"),
            {"d": run_date}
        )

    for file_name in sql_scripts:
        print(f"Running {file_name.name}")

        query = file_name.read_text(encoding="utf-8")

        try:
            with engine.begin() as conn:
                conn.execute(
                    text(query),
                    {"reconciliation_date": run_date}
                )
            print(f"OK: {file_name.name}\n")
        except Exception as e:
            print(f"ERROR in {file_name.name} for {run_date}: {e}")
            raise

def safe_name(value: str) -> str:
    return (
        str(value)
        .strip()
        .lower()
        .replace(" ", "_")
        .replace("/", "_")
        .replace("-", "_")
    )


def export_reports(reconciliation_date,output_dir) -> None:
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    detail_query = text("""
        SELECT *
        FROM reconciliation_detail
        WHERE reconciliation_date = :reconciliation_date
    """)

    summary_query = text("""
        SELECT *
        FROM reconciliation_summary
        WHERE reconciliation_date = :reconciliation_date
    """)


    detail_df = pd.read_sql(
        detail_query,
        con=engine,
        params={"reconciliation_date": reconciliation_date}
    )

    summary_df = pd.read_sql(
        summary_query,
        con=engine,
        params={"reconciliation_date": reconciliation_date}
    )

    if detail_df.empty:
        print("There is no data in reconciliation_detail for that date.")
    if summary_df.empty:
        print("There is no data in reconciliation_summary for that date.")

    reconciliations = sorted(
        set(detail_df["reconciliation"].dropna().unique()).union(
            set(summary_df["reconciliation"].dropna().unique())
        )
    )

    if not reconciliations:
        print("No reconciliations were found for export.")
        return

    for reconciliation in reconciliations:
        recon_name = safe_name(reconciliation).upper()

        detail_subset = detail_df[detail_df["reconciliation"] == reconciliation]
        summary_subset = summary_df[summary_df["reconciliation"] == reconciliation]

        if not detail_subset.empty:
            detail_path = output_path / f"DETAIL_{recon_name}_{reconciliation_date}.csv"
            detail_subset.to_csv(detail_path, index=False, encoding="utf-8-sig")
            print(f"Detail exported: {detail_path} | rows: {len(detail_subset)}")

        if not summary_subset.empty:
            summary_path = output_path / f"SUMMARY_{recon_name}_{reconciliation_date}.csv"
            summary_subset.to_csv(summary_path, index=False, encoding="utf-8-sig")
            print(f"Summary exported: {summary_path} | rows: {len(summary_subset)}")


def date_range(start_date: str, end_date: str):
    current = datetime.strptime(start_date, "%Y-%m-%d").date()
    end = datetime.strptime(end_date, "%Y-%m-%d").date()

    while current <= end:
        yield current.strftime("%Y-%m-%d")
        current += timedelta(days=1)


def run_pipeline():
    if CREATE_SCHEMA:
        create_schema(SCHEMA)

    if LOAD_RAW_TO_POSTGRES:
            for run_date in date_range(START_DATE, END_DATE):
                print(f"\n=== Running load for {run_date} ===")
                write_runtime_params(run_date)
                load_raw_to_postgres(run_date, EBRA_DIR, SCTEF_DIR, RDAP_DIR)

    if RUN_RECONCILIATIONS:
        for run_date in date_range(START_DATE, END_DATE):
            print(f"\n=== Running reconciliation for {run_date} ===")
            write_runtime_params(run_date)
            run_reconciliations(SQL_SCRIPTS, run_date)
    
    if EXPORT_REPORTS:
        for run_date in date_range(START_DATE,END_DATE):
            print(f"\n=== Running export for {run_date} ===")
            write_runtime_params(run_date)
            export_reports(run_date,OUTPUT_DIR)
        consolidate_detail_files(OUTPUT_DIR)
    

    
    print("Pipeline execution completed.")


if __name__ == "__main__":
    run_pipeline()