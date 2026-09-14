CREATE TYPE sales.order_line_type AS TABLE (
    product_id bigint NOT NULL PRIMARY KEY,
    quantity int NOT NULL CHECK(quantity > 0)
);
GO

CREATE OR ALTER PROCEDURE sales.usp_create_order
    @customer_id bigint,
    @lines sales.order_line_type READONLY,
    @discount_amount decimal(19,4)=0,
    @order_id bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS(SELECT 1 FROM sales.customer WHERE customer_id=@customer_id AND is_active=1)
        THROW 50001,'Customer does not exist or is inactive.',1;
    IF NOT EXISTS(SELECT 1 FROM @lines)
        THROW 50002,'Order must contain at least one line.',1;
    IF @discount_amount < 0
        THROW 50003,'Discount cannot be negative.',1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- UPDLOCK/HOLDLOCK serializa a validação e a baixa do saldo.
        IF EXISTS (
            SELECT 1
            FROM @lines l
            LEFT JOIN inventory.product p WITH(UPDLOCK,HOLDLOCK)
              ON p.product_id=l.product_id
            WHERE p.product_id IS NULL OR p.stock_quantity<l.quantity
        ) THROW 50004,'Product not found or insufficient stock.',1;

        INSERT sales.sales_order(customer_id,status,discount_amount)
        VALUES(@customer_id,'PENDING',@discount_amount);
        SET @order_id=SCOPE_IDENTITY();

        INSERT sales.order_item(order_id,product_id,quantity,unit_price)
        SELECT @order_id,p.product_id,l.quantity,p.unit_price
        FROM @lines l
        JOIN inventory.product p ON p.product_id=l.product_id;

        UPDATE p SET stock_quantity=p.stock_quantity-l.quantity
        FROM inventory.product p JOIN @lines l ON l.product_id=p.product_id;

        INSERT inventory.stock_movement(product_id,order_id,movement_type,quantity,reason)
        SELECT product_id,@order_id,'OUT',quantity,N'Reserva do pedido'
        FROM @lines;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE sales.usp_register_payment
    @order_id bigint,
    @amount decimal(19,4),
    @method varchar(20),
    @external_reference varchar(100)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @due decimal(19,4),@paid decimal(19,4);

        SELECT @due=SUM(i.line_total)-o.discount_amount
        FROM sales.sales_order o WITH(UPDLOCK,HOLDLOCK)
        JOIN sales.order_item i ON i.order_id=o.order_id
        WHERE o.order_id=@order_id AND o.status<>'CANCELLED'
        GROUP BY o.discount_amount;

        IF @due IS NULL THROW 50010,'Order not found or cancelled.',1;
        SELECT @paid=COALESCE(SUM(amount),0) FROM sales.payment WHERE order_id=@order_id;
        IF @amount<=0 OR @paid+@amount>@due THROW 50011,'Invalid payment amount.',1;

        INSERT sales.payment(order_id,amount,method,external_reference)
        VALUES(@order_id,@amount,@method,@external_reference);

        IF @paid+@amount=@due
            UPDATE sales.sales_order SET status='PAID' WHERE order_id=@order_id;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        THROW;
    END CATCH
END;
GO
