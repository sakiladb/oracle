#!/usr/bin/env python3
"""Convert MySQL Sakila data dump to Oracle 23ai INSERTs.

- Strips MySQL preamble (SET, LOCK/UNLOCK, USE, COMMIT, /*!...*/).
- Drops the staff.picture BLOB and the address.location GEOMETRY column.
- Skips the film_text table (omitted from our schema).
- Strips backticks from table names in INSERT statements.
- Emits a leading ALTER SESSION so MySQL's ISO timestamp string literals
  ('YYYY-MM-DD HH24:MI:SS') cast implicitly into TIMESTAMP/DATE columns.
- film.special_features stays as the comma-separated string MySQL emits;
  our schema stores it in VARCHAR2(100).

Usage:
    python3 convert_data.py mysql-sakila-data.sql 2-oracle-sakila-data.sql

Input file `mysql-sakila-data.sql` is the upstream MySQL Sakila data dump,
vendored into this repo so the build is self-contained.
"""

import re
import sys

MYSQL_PREAMBLE_PREFIXES = ("SET ", "USE ", "LOCK ", "UNLOCK ", "COMMIT")


def strip_address_geometry(line):
    # /*!50705 0xDEADBEEF,*/  →  ""  (the GEOMETRY column was preceded by ',')
    return re.sub(r'/\*!\d+ 0x[0-9A-Fa-f]+,\*/', '', line)


def strip_staff_picture(line):
    # staff row layout (post-conversion target):
    #   (id, first, last, address_id, [picture removed], email, store_id, ...)
    # MySQL emits the picture column as either a hex BLOB (0xAB...) or NULL.
    line = re.sub(r',0x[0-9A-Fa-f]+,', ',', line)
    # Strip ",NULL," only when it appears immediately after a numeric address_id
    # (to avoid mangling unrelated NULLs elsewhere in a row).
    line = re.sub(r"(\d),NULL,'", r"\1,'", line)
    return line


def strip_table_backticks(line):
    return re.sub(r'INSERT INTO `(\w+)`', r'INSERT INTO \1', line)


def main():
    if len(sys.argv) < 3:
        print("usage: convert_data.py <input-mysql-dump> <output-oracle-sql>",
              file=sys.stderr)
        sys.exit(1)

    input_file, output_file = sys.argv[1], sys.argv[2]

    current_table = None

    with open(input_file, 'r') as f_in, open(output_file, 'w') as f_out:
        f_out.write("-- Sakila Sample Database Data for Oracle 23ai\n")
        f_out.write("-- Converted from mysql-sakila-data.sql\n")
        f_out.write("-- Run as the sakila user against the SAKILA PDB.\n\n")

        # Allow blank lines inside long multi-row INSERTs without sqlplus
        # treating them as statement terminators.
        f_out.write("SET SQLBLANKLINES ON\n")
        # Make the MySQL ISO timestamp literals cast implicitly.
        f_out.write("ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS';\n")
        f_out.write("ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS';\n\n")

        for line in f_in:
            stripped = line.strip()

            # Skip MySQL preamble + transaction control.
            if stripped.startswith(MYSQL_PREAMBLE_PREFIXES):
                continue

            # Skip MySQL conditional comment statements: /*!12345 ... */;
            if stripped.startswith('/*!') and stripped.endswith(';'):
                continue

            # Track which table we are currently emitting INSERTs for.
            m = re.match(r'-- Dumping data for table\s+`?(\w+)`?', stripped)
            if m:
                current_table = m.group(1)
                if current_table != 'film_text':
                    f_out.write(line)
                continue

            # Drop everything for the omitted film_text table.
            if current_table == 'film_text':
                continue

            if stripped.startswith('INSERT INTO'):
                line = strip_table_backticks(line)
                if current_table == 'staff':
                    line = strip_staff_picture(line)
                elif current_table == 'address':
                    line = strip_address_geometry(line)
                f_out.write(line)
            elif stripped.startswith('(') and current_table:
                # Continuation of a multi-row VALUES list.
                if current_table == 'staff':
                    line = strip_staff_picture(line)
                elif current_table == 'address':
                    line = strip_address_geometry(line)
                f_out.write(line)
            elif stripped.startswith('--') or stripped == '':
                f_out.write(line)
            # else: any other line is silently dropped (DELIMITER, etc.)

        f_out.write("\nCOMMIT;\n")


if __name__ == '__main__':
    main()
