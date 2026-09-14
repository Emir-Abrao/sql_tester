SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;

INSERT inventory.category(name)
VALUES (N'Notebooks'), (N'Periféricos'), (N'Monitores');

INSERT inventory.product(category_id, sku, name, unit_price, stock_quantity, reorder_level)
VALUES
(1,'NB-PRO-14',N'Notebook Pro 14',6499.9000,12,3),
(1,'NB-AIR-13',N'Notebook Air 13',4299.9000,8,2),
(2,'KB-MECH-01',N'Teclado Mecânico',449.9000,30,8),
(2,'MS-WLS-01',N'Mouse Sem Fio',189.9000,45,10),
(3,'MN-4K-27',N'Monitor 4K 27',2299.9000,15,4);

INSERT sales.customer(full_name,email,document_number)
VALUES
(N'Ana Martins','ana@example.com','11111111111'),
(N'Bruno Costa','bruno@example.com','22222222222'),
(N'Carla Lima','carla@example.com','33333333333'),
(N'Diego Alves','diego@example.com','44444444444');

INSERT sales.sales_order(customer_id,order_date,status,discount_amount)
VALUES
(1,'2026-06-10T13:00:00','PAID',100),
(2,'2026-06-18T15:30:00','SHIPPED',0),
(1,'2026-07-03T10:15:00','SHIPPED',50),
(3,'2026-07-21T17:40:00','PAID',0),
(4,'2026-08-05T09:20:00','CANCELLED',0),
(2,'2026-08-17T14:10:00','PAID',25);

INSERT sales.order_item(order_id,product_id,quantity,unit_price)
VALUES
(1,1,1,6499.90),(1,4,1,189.90),
(2,3,2,449.90),(2,5,1,2299.90),
(3,2,1,4299.90),(3,3,1,449.90),
(4,5,2,2299.90),
(5,4,3,189.90),
(6,3,1,449.90),(6,4,2,189.90);

INSERT sales.payment(order_id,paid_at,amount,method,external_reference)
SELECT o.order_id, DATEADD(minute,30,o.order_date),
       SUM(i.line_total) - o.discount_amount,
       CASE WHEN o.order_id % 2 = 0 THEN 'CARD' ELSE 'PIX' END,
       CONCAT('PAY-',o.order_id)
FROM sales.sales_order o
JOIN sales.order_item i ON i.order_id=o.order_id
WHERE o.status IN ('PAID','SHIPPED')
GROUP BY o.order_id,o.order_date,o.discount_amount;

INSERT inventory.stock_movement(product_id,order_id,movement_type,quantity,occurred_at,reason)
SELECT i.product_id,i.order_id,'OUT',i.quantity,o.order_date,N'Venda confirmada'
FROM sales.order_item i
JOIN sales.sales_order o ON o.order_id=i.order_id
WHERE o.status IN ('PAID','SHIPPED');

UPDATE p
SET stock_quantity = p.stock_quantity - x.quantity
FROM inventory.product p
JOIN (
    SELECT i.product_id,SUM(i.quantity) quantity
    FROM sales.order_item i
    JOIN sales.sales_order o ON o.order_id=i.order_id
    WHERE o.status IN ('PAID','SHIPPED')
    GROUP BY i.product_id
) x ON x.product_id=p.product_id;

COMMIT;
GO
