"""Tests for convert_data.py (standard library only).

Run: python3 -m unittest -v test_convert_data
"""

import io
import os
import re
import tempfile
import unittest

import convert_data

HERE = os.path.dirname(os.path.abspath(__file__))
MYSQL_DUMP = os.path.join(HERE, 'mysql-sakila-data.sql')
ORACLE_DATA = os.path.join(HERE, '2-oracle-sakila-data.sql')


def convert_str(dump):
    out = io.StringIO()
    convert_data.convert(io.StringIO(dump), out)
    return out.getvalue()


STAFF_ROWS = (
    "-- Dumping data for table staff\n"
    "INSERT INTO `staff` VALUES (1,'Mike','Hillyer',3,0x{hex},'m@x.com',1,1,'Mike',NULL,'2006-02-15 03:57:16'),\n"
    "(2,'Jon','Stephens',4,NULL,'j@x.com',2,1,'Jon',NULL,'2006-02-15 03:57:16');\n"
)


class ConvertTest(unittest.TestCase):

    def test_multi_row_insert_becomes_one_insert_per_row(self):
        dump = (
            "-- Dumping data for table actor\n"
            "INSERT INTO `actor` VALUES (1,'PENELOPE','GUINESS','2006-02-15 04:34:33'),\n"
            "(2,'NICK','WAHLBERG','2006-02-15 04:34:33'),\n"
            "(3,'ED','CHASE','2006-02-15 04:34:33');\n"
            + STAFF_ROWS.format(hex='89504E47AE426082')
        )
        lines = convert_str(dump).splitlines()
        actor = [l for l in lines if l.startswith('INSERT INTO actor')]
        self.assertEqual(len(actor), 3)
        for l in actor:
            self.assertRegex(l, r'^INSERT INTO actor VALUES \(.*\);$')
        self.assertFalse([l for l in lines if l.startswith('(')],
                         'no bare continuation rows may remain')
        self.assertFalse([l for l in lines if l.startswith('INSERT') and l.endswith('),')])

    def test_staff_picture_chunks_fit_line_limit(self):
        hexstr = '89504E47' + 'AB' * (5000 - 8) + 'AE426082'
        self.assertEqual(len(hexstr), 10000)
        out = convert_str(STAFF_ROWS.format(hex=hexstr))
        sizes = [int(n) for n in re.findall(
            r'DBMS_LOB\.WRITEAPPEND\(v_blob, (\d+), HEXTORAW', out)]
        self.assertTrue(sizes)
        self.assertTrue(all(n <= 1000 for n in sizes), sizes)
        self.assertEqual(sum(sizes), 5000)
        self.assertLessEqual(max(len(l) for l in out.splitlines()), 2999)

    def test_line_length_guard_fails(self):
        with tempfile.TemporaryDirectory() as d:
            bad = os.path.join(d, 'bad.sql')
            with open(bad, 'w') as f:
                f.write('ok\n' + 'x' * 3000 + '\n')
            with self.assertRaises(SystemExit):
                convert_data.check_line_lengths(bad)
            good = os.path.join(d, 'good.sql')
            with open(good, 'w') as f:
                f.write(('y' * 2999 + '\n') * 3)
            self.assertIsNone(convert_data.check_line_lengths(good))

    def test_committed_data_file_is_current(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, 'out.sql')
            with open(MYSQL_DUMP) as f_in, open(out, 'w') as f_out:
                convert_data.convert(f_in, f_out)
            with open(out) as f:
                generated = f.read()
        with open(ORACLE_DATA) as f:
            committed = f.read()
        self.assertTrue(generated == committed,
                        '2-oracle-sakila-data.sql is stale: run `make convert-data`')
        lines = generated.splitlines()
        self.assertEqual(sum(l.startswith('INSERT INTO') for l in lines), 46273)
        self.assertEqual(sum('DBMS_LOB.WRITEAPPEND' in l for l in lines), 37)


if __name__ == '__main__':
    unittest.main()
