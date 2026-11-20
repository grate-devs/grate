"""Exercise identical source scenarios and independent expectations for both parsers."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from plan import PARSERS, ROOT

FIRST = 'functions/public.fn_order_totals.sql'
VIEW = 'views/public.v_orders.sql'
REPORT = 'functions/public.fn_report.sql'


def view(name, query):
    return f'CREATE OR REPLACE VIEW {name} AS {query};'


class ParserComparison(unittest.TestCase):
    def check(self, files, order=None, edges=None, outside=None, gaps=(), diagnostic=None):
        plans = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path, sql in files.items():
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(sql, encoding='utf-8')
            for parser in PARSERS:
                with self.subTest(parser=parser):
                    command = [sys.executable, str(ROOT / 'plan.py'), '--parser', parser, str(root)]
                    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                    if order is None or parser in gaps:
                        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                        self.assertEqual(result.stdout, '')
                        if diagnostic:
                            self.assertIn(diagnostic, result.stderr)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    plan = json.loads(result.stdout)
                    self.assertEqual([s['path'] for s in plan['scripts']], order)
                    for script in plan['scripts']:
                        path = script['path']
                        self.assertEqual([d['path'] for d in script['dependencies']], (edges or {}).get(path, []))
                        self.assertEqual(script['outsideReferences'], (outside or {}).get(path, []))
                        source = 'declared' if files[path].startswith('-- Dependencies:') else 'inferred'
                        self.assertTrue(all(d['source'] == source for d in script['dependencies']))
                    self.assertEqual(subprocess.check_output(command, text=True, timeout=30), result.stdout)
                    plans.append(plan)
        if len(plans) == 2:
            self.assertEqual(plans[0], plans[1])

    def base(self):
        return {path.relative_to(ROOT / 'fixtures/base').as_posix(): path.read_text()
                for path in (ROOT / 'fixtures/base').rglob('*.sql')}

    def chain(self, files, gaps=(), diagnostic=None):
        self.check(files, [FIRST, VIEW, REPORT], {VIEW: [FIRST], REPORT: [VIEW]},
                   gaps=gaps, diagnostic=diagnostic)

    def test_scalar_chain(self):
        self.chain(self.base())

    def test_upgrade(self):
        files = self.base()
        files.update({p.relative_to(ROOT / 'fixtures/upgrade').as_posix(): p.read_text()
                      for p in (ROOT / 'fixtures/upgrade').rglob('*.sql')})
        self.chain(files)

    def test_standard_return(self):
        files = self.base()
        files[FIRST] = 'CREATE OR REPLACE FUNCTION public.fn_order_totals() RETURNS integer LANGUAGE sql RETURN 100;'
        self.chain(files)

    def test_standard_atomic_characterization(self):
        files = self.base()
        files[FIRST] = ('CREATE OR REPLACE FUNCTION public.fn_order_totals() RETURNS integer '
                        'LANGUAGE sql BEGIN ATOMIC SELECT 100; END;')
        self.chain(files, gaps=('sqlparsercs',), diagnostic='found BEGIN')

    def test_table_function_characterization(self):
        files = self.base()
        files[FIRST] = ('CREATE OR REPLACE FUNCTION public.fn_order_totals() RETURNS TABLE(total integer) '
                        'LANGUAGE sql AS $$ SELECT 100 $$;')
        files[VIEW] = view('public.v_orders', 'SELECT total FROM public.fn_order_totals()')
        self.chain(files, gaps=('sqlparsercs',), diagnostic='adapter gap')

    def test_view_chain_and_identifier_case(self):
        self.check({'views/a.sql': view('PUBLIC.a', 'SELECT value FROM public."Mixed"'),
                    'views/m.sql': view('public.mixed', 'SELECT 2 AS value'),
                    'views/z.sql': view('public."Mixed"', 'SELECT 1 AS value')},
                   ['views/m.sql', 'views/z.sql', 'views/a.sql'], {'views/a.sql': ['views/z.sql']})

    def test_join_and_derived_query(self):
        files = {'views/a.sql': view('public.a', 'SELECT q.value FROM (SELECT value FROM public.z) q '
                                    'JOIN public.external e ON true'),
                 'views/z.sql': view('public.z', 'SELECT 1 AS value')}
        self.check(files, ['views/z.sql', 'views/a.sql'], {'views/a.sql': ['views/z.sql']},
                   {'views/a.sql': [{'schema': 'public', 'name': 'external', 'kind': 'relation'}]})

    def test_cte_alias(self):
        self.check({'views/a.sql': view('public.a', 'WITH c AS (SELECT value FROM public.z) SELECT value FROM c'),
                    'views/z.sql': view('public.z', 'SELECT 1 AS value')},
                   ['views/z.sql', 'views/a.sql'], {'views/a.sql': ['views/z.sql']})

    def test_distinct_on_expression(self):
        files = self.base()
        files[VIEW] = view('public.v_orders',
                           'SELECT DISTINCT ON (public.fn_order_totals()) orders.total FROM public.orders')
        outside = {VIEW: [{'schema': 'public', 'name': 'orders', 'kind': 'relation'}]}
        self.check(files, [FIRST, VIEW, REPORT], {VIEW: [FIRST], REPORT: [VIEW]}, outside)

    def test_declared_replacement_keeps_incoming_inference(self):
        files = {'views/a.sql': '-- Dependencies: views/m.sql\n' + view('public.a', 'SELECT value FROM public.z'),
                 'views/b.sql': view('public.b', 'SELECT value FROM public.a'),
                 'views/m.sql': view('public.m', 'SELECT 1 AS value'),
                 'views/z.sql': view('public.z', 'SELECT 1 AS value')}
        self.check(files, ['views/m.sql', 'views/a.sql', 'views/b.sql', 'views/z.sql'],
                   {'views/a.sql': ['views/m.sql'], 'views/b.sql': ['views/a.sql']})

    def test_duplicate(self):
        self.check({'views/a.sql': view('public.a', 'SELECT 1'),
                    'views/b.sql': view('PUBLIC.A', 'SELECT 2')}, diagnostic='Duplicate definition')

    def test_cycle(self):
        self.check({'views/a.sql': view('public.a', 'SELECT * FROM public.b'),
                    'views/b.sql': '-- Dependencies: views/a.sql\n' + view('public.b', 'SELECT 1')},
                   diagnostic='Dependency cycle')

    def test_missing_declared_path(self):
        self.check({'views/a.sql': '-- Dependencies: views/missing.sql\n' + view('public.a', 'SELECT 1')},
                   diagnostic='missing declared')

    def test_unsupported_and_malformed_sql(self):
        for sql, path in [
            (view('public.a', 'SELECT * FROM external'), 'views/a.sql'),
            (view('other_db.public.a', 'SELECT 1'), 'views/a.sql'),
            (view('public.a', 'WITH a AS (SELECT * FROM b), b AS (SELECT 1) SELECT * FROM a'), 'views/a.sql'),
            (view('public.a', 'SELECT public.a(1)'), 'views/a.sql'),
            (view('public.a', 'SELECT 1::public.custom_type'), 'views/a.sql'),
            ('CREATE OR REPLACE TEMP VIEW public.a AS SELECT 1;', 'views/a.sql'),
            ('CREATE OR REPLACE FUNCTION public.a(x integer) RETURNS integer LANGUAGE sql AS $$ SELECT x $$;', 'functions/a.sql'),
            ('CREATE OR REPLACE FUNCTION public.a() RETURNS integer LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END $$;', 'functions/a.sql'),
            ('CREATE OR REPLACE FUNCTION public.a() RETURNS integer LANGUAGE sql AS $$ SELECT 1; SELECT 2 $$;', 'functions/a.sql'),
            ('CREATE OR REPLACE VIEW public.a AS SELECT FROM;', 'views/a.sql'),
        ]:
            with self.subTest(sql=sql):
                self.check({path: sql})


if __name__ == '__main__':
    unittest.main(verbosity=2)
