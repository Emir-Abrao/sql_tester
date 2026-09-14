CREATE OR ALTER VIEW analytics.vw_monthly_sales
AS
SELECT
    DATEFROMPARTS(YEAR(o.order_date),MONTH(o.order_date),1) AS month_start,
    COUNT_BIG(DISTINCT o.order_id) AS orders,
    COUNT_BIG(DISTINCT o.customer_id) AS customers,
    SUM(i.line_total) - SUM(o.discount_amount * 1.0 / NULLIF(x.item_count,0)) AS net_revenue,
    SUM(i.quantity) AS units_sold
FROM sales.sales_order o
JOIN sales.order_item i ON i.order_id=o.order_id
CROSS APPLY (SELECT COUNT(*) item_count FROM sales.order_item z WHERE z.order_id=o.order_id) x
WHERE o.status IN ('PAID','SHIPPED')
GROUP BY DATEFROMPARTS(YEAR(o.order_date),MONTH(o.order_date),1);
GO

CREATE OR ALTER VIEW analytics.vw_customer_rfm
AS
WITH totals AS (
    SELECT o.order_id,o.customer_id,o.order_date,
           SUM(i.line_total)-o.discount_amount AS order_total
    FROM sales.sales_order o
    JOIN sales.order_item i ON i.order_id=o.order_id
    WHERE o.status IN ('PAID','SHIPPED')
    GROUP BY o.order_id,o.customer_id,o.order_date,o.discount_amount
), rfm AS (
    SELECT customer_id,
           DATEDIFF(day,MAX(order_date),SYSUTCDATETIME()) recency_days,
           COUNT(*) frequency,
           SUM(order_total) monetary
    FROM totals GROUP BY customer_id
)
SELECT c.customer_id,c.full_name,r.recency_days,r.frequency,r.monetary,
       NTILE(5) OVER (ORDER BY r.recency_days DESC) recency_score,
       NTILE(5) OVER (ORDER BY r.frequency) frequency_score,
       NTILE(5) OVER (ORDER BY r.monetary) monetary_score
FROM rfm r
JOIN sales.customer c ON c.customer_id=r.customer_id;
GO

-- Ranking mensal de produtos, participação na receita e crescimento mês contra mês.
WITH product_month AS (
    SELECT DATEFROMPARTS(YEAR(o.order_date),MONTH(o.order_date),1) month_start,
           p.product_id,p.sku,p.name,
           SUM(i.quantity) units,
           SUM(i.line_total) revenue
    FROM sales.sales_order o
    JOIN sales.order_item i ON i.order_id=o.order_id
    JOIN inventory.product p ON p.product_id=i.product_id
    WHERE o.status IN ('PAID','SHIPPED')
    GROUP BY DATEFROMPARTS(YEAR(o.order_date),MONTH(o.order_date),1),p.product_id,p.sku,p.name
), metrics AS (
    SELECT *,
           DENSE_RANK() OVER(PARTITION BY month_start ORDER BY revenue DESC) revenue_rank,
           revenue/SUM(revenue) OVER(PARTITION BY month_start) revenue_share,
           LAG(revenue) OVER(PARTITION BY product_id ORDER BY month_start) previous_revenue
    FROM product_month
)
SELECT *, (revenue-previous_revenue)/NULLIF(previous_revenue,0) mom_growth
FROM metrics
ORDER BY month_start,revenue_rank;
GO

-- Clientes cuja receita acumulada compõe aproximadamente os primeiros 80% (Pareto).
WITH customer_revenue AS (
    SELECT o.customer_id,SUM(i.line_total-o.discount_amount*1.0/x.item_count) revenue
    FROM sales.sales_order o
    JOIN sales.order_item i ON i.order_id=o.order_id
    CROSS APPLY(SELECT COUNT(*) item_count FROM sales.order_item z WHERE z.order_id=o.order_id)x
    WHERE o.status IN ('PAID','SHIPPED')
    GROUP BY o.customer_id
), pareto AS (
    SELECT *,
      SUM(revenue) OVER(ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
      / SUM(revenue) OVER() cumulative_share
    FROM customer_revenue
)
SELECT c.full_name,p.revenue,p.cumulative_share
FROM pareto p JOIN sales.customer c ON c.customer_id=p.customer_id
WHERE p.cumulative_share-p.revenue/SUM(p.revenue) OVER() < .80
ORDER BY p.revenue DESC;
GO
