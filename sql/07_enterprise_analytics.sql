-- Cohort mensal: retenção de clientes por meses desde a primeira compra.
WITH purchases AS (
    SELECT DISTINCT o.customer_id,
      DATEFROMPARTS(YEAR(o.order_date),MONTH(o.order_date),1) order_month
    FROM sales.sales_order o WHERE o.status IN('PAID','SHIPPED')
), cohorts AS (
    SELECT customer_id,MIN(order_month) cohort_month FROM purchases GROUP BY customer_id
), retention AS (
    SELECT c.cohort_month,DATEDIFF(month,c.cohort_month,p.order_month) month_number,
           COUNT(DISTINCT p.customer_id) active_customers
    FROM purchases p JOIN cohorts c ON c.customer_id=p.customer_id
    GROUP BY c.cohort_month,DATEDIFF(month,c.cohort_month,p.order_month)
), sized AS (
    SELECT *,MAX(CASE WHEN month_number=0 THEN active_customers END)
      OVER(PARTITION BY cohort_month) cohort_size
    FROM retention
)
SELECT cohort_month,month_number,active_customers,cohort_size,
       CONVERT(decimal(9,4),active_customers*1.0/NULLIF(cohort_size,0)) retention_rate
FROM sized ORDER BY cohort_month,month_number;
GO

-- Customer Lifetime Value simplificado com frequência, ticket e tempo ativo.
WITH order_value AS (
    SELECT o.customer_id,o.order_id,o.order_date,
           SUM(i.line_total)-o.discount_amount revenue
    FROM sales.sales_order o JOIN sales.order_item i ON i.order_id=o.order_id
    WHERE o.status IN('PAID','SHIPPED')
    GROUP BY o.customer_id,o.order_id,o.order_date,o.discount_amount
), customer_metrics AS (
    SELECT customer_id,COUNT(*) orders,AVG(revenue) avg_ticket,SUM(revenue) revenue,
           DATEDIFF(day,MIN(order_date),MAX(order_date))+1 active_days
    FROM order_value GROUP BY customer_id
)
SELECT c.customer_id,c.full_name,m.orders,m.avg_ticket,m.revenue,m.active_days,
       m.avg_ticket*m.orders/NULLIF(m.active_days,0)*365.0 estimated_annual_clv,
       PERCENT_RANK() OVER(ORDER BY m.revenue) revenue_percentile
FROM customer_metrics m JOIN sales.customer c ON c.customer_id=m.customer_id
ORDER BY estimated_annual_clv DESC;
GO

-- Classificação ABC por contribuição acumulada de receita.
WITH product_sales AS (
    SELECT p.product_id,p.sku,p.name,SUM(i.line_total) revenue,SUM(i.quantity) units
    FROM inventory.product p
    JOIN sales.order_item i ON i.product_id=p.product_id
    JOIN sales.sales_order o ON o.order_id=i.order_id
    WHERE o.status IN('PAID','SHIPPED')
    GROUP BY p.product_id,p.sku,p.name
), contribution AS (
    SELECT *,
      SUM(revenue) OVER(ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
        /NULLIF(SUM(revenue) OVER(),0) cumulative_share
    FROM product_sales
)
SELECT *,CASE WHEN cumulative_share<=.80 THEN 'A'
              WHEN cumulative_share<=.95 THEN 'B' ELSE 'C' END abc_class
FROM contribution ORDER BY revenue DESC;
GO

-- Cobertura de estoque usando velocidade móvel de 30 dias.
WITH demand AS (
    SELECT p.product_id,
      SUM(CASE WHEN m.movement_type='OUT' AND m.occurred_at>=DATEADD(day,-30,SYSUTCDATETIME())
               THEN m.quantity ELSE 0 END)/30.0 avg_daily_demand
    FROM inventory.product p
    LEFT JOIN inventory.stock_movement m ON m.product_id=p.product_id
    GROUP BY p.product_id
)
SELECT p.product_id,p.sku,p.name,p.stock_quantity,d.avg_daily_demand,
       p.stock_quantity/NULLIF(d.avg_daily_demand,0) days_of_cover,
       CASE WHEN d.avg_daily_demand=0 THEN 'NO_DEMAND'
            WHEN p.stock_quantity/NULLIF(d.avg_daily_demand,0)<7 THEN 'CRITICAL'
            WHEN p.stock_quantity/NULLIF(d.avg_daily_demand,0)<21 THEN 'REORDER'
            ELSE 'HEALTHY' END inventory_health
FROM inventory.product p JOIN demand d ON d.product_id=p.product_id;
GO

CREATE TABLE analytics.daily_sales_snapshot (
    snapshot_date date NOT NULL,
    tenant_id int NOT NULL,
    gross_revenue decimal(19,4) NOT NULL,
    discount_amount decimal(19,4) NOT NULL,
    net_revenue decimal(19,4) NOT NULL,
    orders int NOT NULL,
    customers int NOT NULL,
    units int NOT NULL,
    loaded_at datetime2(7) NOT NULL CONSTRAINT df_snapshot_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_daily_snapshot PRIMARY KEY(snapshot_date,tenant_id)
);
GO

CREATE OR ALTER PROCEDURE analytics.usp_refresh_daily_sales
    @from_date date,
    @to_date date
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @from_date>@to_date THROW 53001,'Invalid date range.',1;

    BEGIN TRANSACTION;
    DELETE analytics.daily_sales_snapshot
    WHERE snapshot_date BETWEEN @from_date AND @to_date;

    INSERT analytics.daily_sales_snapshot
      (snapshot_date,tenant_id,gross_revenue,discount_amount,net_revenue,orders,customers,units)
    SELECT CONVERT(date,o.order_date),o.tenant_id,SUM(i.line_total),
           SUM(o.discount_amount*1.0/x.item_count),
           SUM(i.line_total-o.discount_amount*1.0/x.item_count),
           COUNT(DISTINCT o.order_id),COUNT(DISTINCT o.customer_id),SUM(i.quantity)
    FROM sales.sales_order o
    JOIN sales.order_item i ON i.order_id=o.order_id
    CROSS APPLY(SELECT COUNT(*) item_count FROM sales.order_item z WHERE z.order_id=o.order_id)x
    WHERE o.status IN('PAID','SHIPPED')
      AND o.order_date>=@from_date AND o.order_date<DATEADD(day,1,@to_date)
    GROUP BY CONVERT(date,o.order_date),o.tenant_id;
    COMMIT;
END;
GO
