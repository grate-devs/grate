CREATE OR REPLACE VIEW public.v_orders AS
SELECT public.fn_order_totals() AS total,
       public.fn_order_totals() - 15 AS net_total;
