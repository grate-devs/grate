CREATE OR REPLACE FUNCTION public.fn_report()
RETURNS integer LANGUAGE sql
AS $$ SELECT orders.total FROM public.v_orders AS orders $$;
