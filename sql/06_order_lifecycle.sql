CREATE OR ALTER PROCEDURE sales.usp_create_order_v2
    @tenant_id int,
    @customer_id bigint,
    @lines sales.order_line_type READONLY,
    @discount_amount decimal(19,4)=0,
    @idempotency_key uniqueidentifier,
    @request_hash binary(32),
    @order_id bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @correlation_id uniqueidentifier=NEWID();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @order_id=TRY_CONVERT(bigint,resource_id)
        FROM integration.idempotency_key WITH(UPDLOCK,HOLDLOCK)
        WHERE tenant_id=@tenant_id AND idempotency_key=@idempotency_key
          AND operation='CREATE_ORDER' AND expires_at>SYSUTCDATETIME();

        IF @order_id IS NOT NULL
        BEGIN
            IF EXISTS(SELECT 1 FROM integration.idempotency_key
                      WHERE tenant_id=@tenant_id AND idempotency_key=@idempotency_key
                        AND request_hash<>@request_hash)
                THROW 52001,'Idempotency key reused with a different payload.',1;
            COMMIT;
            RETURN;
        END

        IF NOT EXISTS(SELECT 1 FROM sales.customer
                      WHERE customer_id=@customer_id AND tenant_id=@tenant_id AND is_active=1)
            THROW 52002,'Active customer not found in tenant.',1;
        IF NOT EXISTS(SELECT 1 FROM @lines) THROW 52003,'Order requires lines.',1;

        IF EXISTS(
            SELECT 1 FROM @lines l
            LEFT JOIN inventory.product p WITH(UPDLOCK,HOLDLOCK)
              ON p.product_id=l.product_id AND p.tenant_id=@tenant_id
            WHERE p.product_id IS NULL OR p.stock_quantity<l.quantity
        ) THROW 52004,'Product not found or insufficient stock.',1;

        INSERT sales.sales_order(tenant_id,customer_id,status,discount_amount)
        VALUES(@tenant_id,@customer_id,'PENDING',@discount_amount);
        SET @order_id=SCOPE_IDENTITY();

        INSERT sales.order_item(order_id,product_id,quantity,unit_price)
        SELECT @order_id,p.product_id,l.quantity,p.unit_price
        FROM @lines l JOIN inventory.product p
          ON p.product_id=l.product_id AND p.tenant_id=@tenant_id;

        UPDATE p SET stock_quantity-=l.quantity
        FROM inventory.product p JOIN @lines l ON l.product_id=p.product_id
        WHERE p.tenant_id=@tenant_id;

        INSERT inventory.stock_movement(product_id,order_id,movement_type,quantity,reason)
        SELECT product_id,@order_id,'OUT',quantity,N'Order reservation' FROM @lines;

        INSERT sales.order_status_history(order_id,from_status,to_status,correlation_id,reason)
        VALUES(@order_id,NULL,'PENDING',@correlation_id,N'Order created');

        INSERT integration.idempotency_key
          (tenant_id,idempotency_key,operation,resource_id,request_hash,expires_at)
        VALUES(@tenant_id,@idempotency_key,'CREATE_ORDER',CONVERT(varchar(100),@order_id),
               @request_hash,DATEADD(hour,24,SYSUTCDATETIME()));

        INSERT integration.outbox_event
          (tenant_id,aggregate_type,aggregate_id,event_type,payload)
        VALUES(@tenant_id,'Order',CONVERT(varchar(100),@order_id),'OrderCreated',
          (SELECT @order_id orderId,@tenant_id tenantId,@customer_id customerId,
                  @correlation_id correlationId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER));

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE sales.usp_cancel_order
    @tenant_id int,
    @order_id bigint,
    @reason nvarchar(300),
    @expected_version binary(8)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status varchar(20),@correlation_id uniqueidentifier=NEWID();

    BEGIN TRY
        BEGIN TRANSACTION;
        SELECT @status=status FROM sales.sales_order WITH(UPDLOCK,HOLDLOCK)
        WHERE order_id=@order_id AND tenant_id=@tenant_id;

        IF @status IS NULL THROW 52010,'Order not found.',1;
        IF @status IN('SHIPPED','CANCELLED') THROW 52011,'Order cannot be cancelled in its current state.',1;

        UPDATE p SET stock_quantity+=i.quantity
        FROM inventory.product p
        JOIN sales.order_item i ON i.product_id=p.product_id
        WHERE i.order_id=@order_id;

        INSERT inventory.stock_movement(product_id,order_id,movement_type,quantity,reason)
        SELECT product_id,@order_id,'IN',quantity,CONCAT(N'Cancellation: ',@reason)
        FROM sales.order_item WHERE order_id=@order_id;

        UPDATE sales.sales_order SET status='CANCELLED' WHERE order_id=@order_id;

        INSERT sales.order_status_history(order_id,from_status,to_status,correlation_id,reason)
        VALUES(@order_id,@status,'CANCELLED',@correlation_id,@reason);

        INSERT integration.outbox_event(tenant_id,aggregate_type,aggregate_id,event_type,payload)
        VALUES(@tenant_id,'Order',CONVERT(varchar(100),@order_id),'OrderCancelled',
          (SELECT @order_id orderId,@tenant_id tenantId,@reason reason,
                  @correlation_id correlationId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER));
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE integration.usp_claim_outbox_batch
    @batch_size int=100
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH batch AS (
        SELECT TOP(@batch_size) *
        FROM integration.outbox_event WITH(UPDLOCK,READPAST,ROWLOCK)
        WHERE processed_at IS NULL AND retry_count<10
        ORDER BY occurred_at,event_id
    )
    UPDATE batch SET retry_count+=1
    OUTPUT inserted.event_id,inserted.tenant_id,inserted.event_type,
           inserted.aggregate_type,inserted.aggregate_id,inserted.payload;
END;
GO
