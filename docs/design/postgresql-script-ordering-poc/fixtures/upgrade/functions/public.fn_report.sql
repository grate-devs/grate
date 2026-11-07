CREATE OR REPLACE FUNCTION public.fn_report()
RETURNS integer LANGUAGE sql
AS $$ SELECT orders.net_total FROM public.v_orders AS orders $$;
