# 📊 ReconcileFlow — PostgreSQL Reconciliation Pipeline

## 🚀 Overview

**ReconcileFlow (PostgreSQL version)** is a database-driven reconciliation pipeline designed to automate financial transaction matching using SQL as the core processing engine.

This project implements reconciliation logic directly inside PostgreSQL, while Python is used for orchestration, data ingestion, and report generation.

It simulates real-world banking operations by comparing multiple financial data sources such as:

* **EBRA / EBRV** (central bank transaction logs)
* **RDAP** (internal bank records)
* **SCTEF** (transaction processing system)

The system processes high-volume transaction data and transforms manual reconciliation workflows into a fully automated pipeline.

> 💡 This version emphasizes SQL-based transformation and scalable data processing, similar to real-world data warehouse workflows.

---

## 📊 Real-World Context

This project is inspired by reconciliation workflows used in banking operations, where:

* Daily volumes can reach hundreds of thousands of transactions
* Manual reconciliation processes can take several hours
* Data inconsistencies can impact operational and financial accuracy

This pipeline demonstrates how automation can significantly reduce processing time and improve reliability.

---

## 🏗️ Architecture (SQL-Based)

This version of ReconcileFlow follows a **database-centric architecture**:

```
raw files (EBRA / RDAP / SCTEF)
            ↓
data ingestion (Python → PostgreSQL)
            ↓
raw staging tables
            ↓
SQL transformations (CTEs, joins, window functions)
            ↓
reconciliation results (detail + summary tables)
            ↓
Python export layer (CSV reports)
```

* **PostgreSQL** handles all transformation and reconciliation logic
* **SQL scripts** define business rules and matching strategies
* **Python** orchestrates execution and data flow

---

## 🧠 Key Concepts

* **TEF (Transferencia Electrónica de Fondos)**
  Equivalent to **EFT (Electronic Funds Transfer)**

* This project models:

  * Incoming transfers
  * Outgoing transfers
  * Internal payments
  * External payment flows

---

## 📂 Project Structure

```
data/
  ├── EBRA/
  ├── RDAP/
  ├── SCTEF/

sql/
  ├── schema.sql
  ├── incoming_eft.sql
  ├── incoming_payments.sql
  ├── internal_payments.sql
  └── outgoing_eft.sql

scripts/
  └── orchestrator.py

output/
  ├── DETAIL_*.csv
  ├── SUMMARY_*.csv

docs/

README.md
requirements.txt
.env (not included in repo)
```

---

## 🗄️ Database Layer

The system uses PostgreSQL as the central processing engine.

### 🔹 Raw staging tables

* `ebra_raw`
* `ebrv_raw`
* `sctef_raw`
* `rdap_1172_raw`
* `rdap_1178_raw`

### 🔹 Output tables

* `reconciliation_detail`
* `reconciliation_summary`

These tables store the final reconciliation results used for reporting.

---

## 🧠 SQL Reconciliation Logic

Each reconciliation flow is implemented using SQL scripts based on:

* Common Table Expressions (CTEs)
* Window functions (`ROW_NUMBER`)
* Controlled join strategies (FULL OUTER JOIN, LEFT JOIN)
* Business-driven filtering rules

### Key features:

* Duplicate-safe matching using row-level sequencing
* Separation of approved vs reversed transactions (EBRA vs EBRV)
* Deterministic reconciliation across multiple data sources
* Clear classification of matched and unmatched records

---

## ⚡ Orchestration Pipeline

Located in:

```
scripts/orchestrator.py
```

### Responsibilities:

* Create database schema
* Load raw files into PostgreSQL
* Execute SQL reconciliation scripts
* Export detail and summary reports
* Consolidate outputs (monthly + global)

---

## 📈 Outputs

The pipeline generates multiple layers of outputs:

### 🔹 Transaction-Level Detail

```
DETAIL_<PROCESS>_<DATE>.csv
```

Contains row-level reconciliation results with transaction status.

---

### 🔹 Daily Summary

```
SUMMARY_<PROCESS>_<DATE>.csv
```

Aggregated metrics by reconciliation status.

---

### 🔹 Aggregated Views

```
DETAIL_YYYY-MM.csv  
DETAIL_ALL.csv
```

Monthly and global consolidation of reconciliation results.

---

## ▶️ How to Run

### 1. Configure environment

Create a `.env` file in the project root:

```
DB_USER=your_user
DB_PASSWORD=your_password
DB_HOST=localhost
DB_PORT=5432
DB_NAME=your_database
```

---

### 2. Install dependencies

```bash
pip install -r requirements.txt
```

---

### 3. Run full pipeline

```bash
python scripts/orchestrator.py
```

---

## 🧪 Data Features

* Fixed-width file parsing (EBRA / RDAP)

* CSV ingestion (SCTEF)

* Data normalization:

  * ID standardization
  * Amount casting
  * RUT formatting

* Timestamp transformation:

  * TRANSACTION_DATE
  * TRANSACTION_TIME

---

## 💡 Key Skills Demonstrated

* SQL-based data transformation (CTEs, window functions)
* Data pipeline orchestration with Python
* Database-driven ETL processes
* Financial reconciliation logic
* Handling high-volume transactional data
* Modular and scalable pipeline design
* Real-world business logic modeling

---

## 🎯 Business Value

This project demonstrates how to:

* Replace manual reconciliation workflows
* Improve data accuracy and traceability
* Enable scalable data processing using SQL
* Separate ingestion, transformation, and reporting layers
* Build production-style data pipelines

---

## 🚀 Future Improvements

* Integration with data warehouses (BigQuery / Snowflake)
* dbt transformation layer
* Airflow orchestration
* Data quality validation and alerting
* BI dashboards (Power BI / Looker)

---

## 👨‍💻 Author

Jonathan Maldonado — Data Analyst

Focused on:

* Data automation
* Financial systems
* Scalable data pipelines
* Real-world problem solving

---

## 📌 Notes

This project is based on real-world reconciliation logic adapted for portfolio demonstration purposes.
