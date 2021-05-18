import asyncio
import os
from typing import List

import asyncpg
import typer
import orjson
from smart_open import open
from enum import Enum

from pypgstac import __version__ as version

import logging

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

app = typer.Typer()

dirname = os.path.dirname(__file__)
migrations_dir = os.path.join(dirname, "migrations")


def pglogger(conn, message):
    logging.debug(message)


async def con_init(conn):
    """Use orjson for json returns."""
    await conn.set_type_codec(
        "json",
        encoder=orjson.dumps,
        decoder=orjson.loads,
        schema="pg_catalog",
    )
    await conn.set_type_codec(
        "jsonb",
        encoder=orjson.dumps,
        decoder=orjson.loads,
        schema="pg_catalog",
    )


class DB:
    pg_connection_string = None
    connection = None

    def __init__(self, pg_connection_string: str = None):
        self.pg_connection_string = pg_connection_string

    async def create_connection(self):
        self.connection = await asyncpg.connect(
            self.pg_connection_string,
            server_settings={
                "search_path": "pgstac,public",
                "application_name": "pypgstac",
            },
        )
        await con_init(self.connection)
        return self.connection

    async def __aenter__(self):
        if self.connection is None:
            await self.create_connection()
        return self.connection

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.connection.close()


async def run_migration(dsn: str = None):
    conn = await asyncpg.connect(dsn=dsn)
    async with conn.transaction():
        try:
            oldversion = await conn.fetchval(
                """
                SELECT version FROM pgstac.migrations
                ORDER BY datetime DESC LIMIT 1;
                """
            )
        except asyncpg.exceptions.UndefinedTableError:
            oldversion = None
    logging.debug(
        f"Old Version: {oldversion} Migrations Dir: {migrations_dir}"
    )
    if oldversion is None or oldversion == {version}:
        migration_file = os.path.join(migrations_dir, f"pgstac.{version}.sql")
    else:
        migration_file = os.path.join(
            migrations_dir, f"pgstac.{oldversion}-{version}.sql"
        )

    if not os.path.exists(migration_file):
        raise Exception(
            f"Pypgstac does not have a migration from {oldversion} to {version} ({migration_file})"
        )

    with open(migration_file) as f:
        migration_sql = f.read()
        logging.debug(migration_sql)
        async with conn.transaction():
            conn.add_log_listener(pglogger)
            await conn.execute(migration_sql)
            await conn.execute(
                """
                INSERT INTO pgstac.versions (version)
                VALUES ($1);
                """,
                version,
            )

    await conn.close()
    return version


@app.command()
def migrate(dsn: str = None):
    typer.echo(asyncio.run(run_migration(dsn)))


class loadopt(str, Enum):
    insert = "insert"
    insert_ignore = "insert_ignore"
    upsert = "upsert"


class tables(str, Enum):
    items = "items"
    collections = "collections"


async def aiter(list: List):
    for i in list:
        logger.debug(orjson.dumps(i))
        yield orjson.dumps(i) + b'\n'


async def copy(iter, table: tables, conn: asyncpg.Connection):
    logging.debug(f"copying to {table} directly")
    if isinstance(iter, List):
        logger.debug("Converting List into Async Iterator")
        iter = aiter(iter)
    async with conn.transaction():
        logger.debug("Copying data")
        await conn.copy_to_table(table, source=iter, columns=["content"])
        logger.debug("Backfilling partitions")
        await conn.execute(
            f"""
            SELECT backfill_partitions();
        """
        )
        logger.debug("Copy complete")


async def copy_ignore_duplicates(
    iter, table: tables, conn: asyncpg.Connection
):
    logging.debug(f"inserting to {table} ignoring duplicates")
    if isinstance(iter, List):
        logger.debug("Converting List into Async Iterator")
        iter = aiter(iter)
    async with conn.transaction():
        await conn.execute(
            """
            CREATE TEMP TABLE pgstactemp (content jsonb)
            ON COMMIT DROP;
        """
        )
        await conn.copy_to_table(
            "pgstactemp", source=iter, columns=["content"]
        )
        logger.debug("Data Copied")
        await conn.execute(
            """
            SELECT make_partitions(
                min((content->>'datetime')::timestamptz),
                max((content->>'datetime')::timestamptz)
            ) FROM pgstactemp;
        """
        )
        logger.debug("Made Partitions")
        await conn.execute(
            f"""
            INSERT INTO {table} (content)
            SELECT content FROM pgstactemp
            ON CONFLICT DO NOTHING;
        """
        )
        logger.debug("Data Inserted")


async def copy_upsert(iter, table: tables, conn: asyncpg.Connection):
    logging.debug(f"upserting to {table}")
    if isinstance(iter, List):
        logger.debug("Converting List into Async Iterator")
        iter = aiter(iter)
    async with conn.transaction():
        await conn.execute(
            """
            CREATE TEMP TABLE pgstactemp (content jsonb)
            ON COMMIT DROP;
        """
        )
        await conn.copy_to_table(
            "pgstactemp", source=iter, columns=["content"]
        )
        logger.debug("Data Copied")
        if table == "collections":
            await conn.execute(
                f"""
                INSERT INTO collections (content)
                SELECT content FROM pgstactemp
                ON CONFLICT (id) DO UPDATE
                SET content = EXCLUDED.content
                WHERE collections.content IS DISTINCT FROM EXCLUDED.content;
            """
            )
        if table == "items":
            logger.debug("Upserting Data")
            await conn.execute(
                f"""
                SELECT upsert_item(content)
                FROM pgstactemp;
            """
            )


async def load_iterator(
    iter, table: tables, conn: asyncpg.Connection, method: loadopt = "insert"
):
    if method == "insert":
        await copy(iter, tables, conn)
    elif method == "insert_ignore":
        await copy_ignore_duplicates(iter, tables, conn)
    else:
        await copy_upsert(iter, table, conn)


async def load_ndjson(
    file: str, table: tables, method: loadopt = "insert", dsn: str = None
):
    with open(file, "rb") as f:
        async with DB(dsn) as conn:
            await load_iterator(f, tables, conn, method)


@app.command()
def load(
    table: tables,
    file: str,
    dsn: str = None,
    method: loadopt = typer.Option(
        "insert", prompt="How to deal conflicting ids"
    ),
):
    typer.echo(
        asyncio.run(
            load_ndjson(file=file, table=table, dsn=dsn, method=method)
        )
    )


if __name__ == "__main__":
    app()
