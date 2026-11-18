CREATE OR ALTER VIEW dbo.vOrders
AS
SELECT totals.Total
FROM dbo.fnOrderTotals() AS totals;
