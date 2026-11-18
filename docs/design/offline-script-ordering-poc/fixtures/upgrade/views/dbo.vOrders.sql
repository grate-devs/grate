CREATE OR ALTER VIEW dbo.vOrders
AS
SELECT totals.Total, totals.Total - 15 AS NetTotal
FROM dbo.fnOrderTotals() AS totals;
