-- ============================================================
-- SwiftDrop Delivery Program — Incentive Strategy Analysis
-- Full SQL Framework
-- ============================================================
-- This query builds a customer-level behavioral profile to
-- evaluate the delivery incentive program. It identifies each
-- customer's first delivery transaction, determines whether
-- they are net new or existing, and measures their return and
-- retention behavior after that first delivery.
-- ============================================================


-- ============================================================
-- CTE 1: first_delivery_txn
-- ============================================================
-- Identifies each customer's FIRST delivery transaction using
-- QUALIFY + ROW_NUMBER. This anchors the post-delivery
-- measurement window used throughout the rest of the analysis.
-- ============================================================

WITH first_delivery_txn AS (
    SELECT
        customer_group_id,
        transaction_key  AS first_delivery_transaction_key,
        transaction_date AS first_delivery_txn_date,
        net_sales        AS first_delivery_txn_net_sales
    FROM fct_transactions
    WHERE order_made = 'Other'
      AND source_name NOT IN (excluded_sources)
      AND transaction_date > program_launch_date
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_group_id
        ORDER BY transaction_date, transaction_key
    ) = 1
)


-- ============================================================
-- CTE 2: all_first_purchase
-- ============================================================
-- Finds each customer's FIRST transaction of ANY type
-- (delivery or retail). Comparing this date to
-- first_delivery_txn_date determines whether the customer is
-- net new (their first-ever transaction was a delivery order)
-- or existing (they had a retail history before delivery).
-- ============================================================

, all_first_purchase AS (
    SELECT
        customer_group_id,
        MIN(transaction_date) AS first_retail_txn_date
    FROM fct_transactions
    WHERE source_name NOT IN (excluded_sources)
    GROUP BY customer_group_id
)


-- ============================================================
-- CTE 3: post_delivery
-- ============================================================
-- Counts all delivery transactions that occurred AFTER the
-- customer's first delivery transaction — this measures return
-- behavior (did the customer come back for a 2nd, 3rd, etc.
-- delivery order) and the revenue generated from those repeat
-- orders.
-- ============================================================

, post_delivery AS (
    SELECT
        fdt.customer_group_id,
        COUNT(DISTINCT dt.transaction_key) AS post_delivery_txns,
        SUM(dt.net_sales)                  AS post_delivery_net_sales
    FROM first_delivery_txn AS fdt
    LEFT JOIN fct_transactions AS dt
        ON fdt.customer_group_id = dt.customer_group_id
        AND dt.order_made = 'Other'
        AND dt.transaction_date > fdt.first_delivery_txn_date
    GROUP BY 1
)


-- ============================================================
-- CTE 4: customer_base
-- ============================================================
-- Assembles the full customer profile with all behavioral
-- flags needed for the final analysis:
--   - customer_type: 'net_new' if their first-ever transaction
--     was a delivery order, 'existing' otherwise
--   - is_net_new_flag: 1/0 version of the above, used for rate
--     calculations downstream (AVG or DIV0 + SUM)
--   - is_returned_net_new: 1 if a net new customer came back
--     for at least one more delivery order
--   - is_secured_net_new: 1 if a net new customer reached a
--     confirmed habit of 3+ post-delivery orders
-- ============================================================

, customer_base AS (
    SELECT
        fdt.customer_group_id,
        fdt.first_delivery_txn_date,
        fdt.first_delivery_txn_net_sales,
        af.first_retail_txn_date,
        COALESCE(pd.post_delivery_txns, 0)      AS post_delivery_txns,
        COALESCE(pd.post_delivery_net_sales, 0) AS post_delivery_net_sales,

        CASE
            WHEN af.first_retail_txn_date = fdt.first_delivery_txn_date
            THEN 'net_new' ELSE 'existing'
        END AS customer_type,

        -- net new customer flag (1 = net new, 0 = existing)
        -- aggregate this column with AVG() or DIV0(SUM(...), COUNT(...))
        -- in downstream reporting to get the % of customers in a
        -- given cohort who are net new
        CASE
            WHEN af.first_retail_txn_date = fdt.first_delivery_txn_date
            THEN 1 ELSE 0
        END AS is_net_new_flag,

        CASE
            WHEN af.first_retail_txn_date = fdt.first_delivery_txn_date
                AND COALESCE(pd.post_delivery_txns, 0) > 0
            THEN 1 ELSE 0
        END AS is_returned_net_new,

        CASE
            WHEN af.first_retail_txn_date = fdt.first_delivery_txn_date
                AND COALESCE(pd.post_delivery_txns, 0) > 3
            THEN 1 ELSE 0
        END AS is_secured_net_new

    FROM first_delivery_txn AS fdt
    LEFT JOIN all_first_purchase AS af ON fdt.customer_group_id = af.customer_group_id
    LEFT JOIN post_delivery AS pd      ON fdt.customer_group_id = pd.customer_group_id
)

SELECT * FROM customer_base;


-- ============================================================
-- Final Aggregation: Weekly Cohort Summary
-- ============================================================
-- Rolls customer_base up to the weekly cohort level, including
-- the net new customer acquisition rate, return stickiness rate,
-- and secured stickiness rate used throughout the analysis.
-- ============================================================

SELECT
    DATE_TRUNC('week', first_delivery_txn_date) AS first_delivery_week,
    COUNT(DISTINCT customer_group_id)           AS first_delivery_customers,
    SUM(is_net_new_flag)                        AS net_new_customers,
    DIV0(SUM(is_net_new_flag),
        COUNT(DISTINCT customer_group_id))      AS net_new_customer_rate,
    SUM(CASE WHEN is_returned_net_new = 1
        THEN 1 ELSE 0 END)                      AS returned_net_new_customers,
    SUM(CASE WHEN is_secured_net_new = 1
        THEN 1 ELSE 0 END)                      AS secured_net_new_customers,
    DIV0(
        SUM(CASE WHEN is_returned_net_new = 1 THEN 1 ELSE 0 END),
        COUNT(DISTINCT customer_group_id)
    )                                            AS return_stickiness_rate,
    DIV0(
        SUM(CASE WHEN is_secured_net_new = 1 THEN 1 ELSE 0 END),
        COUNT(DISTINCT customer_group_id)
    )                                            AS secured_stickiness_rate
FROM customer_base
GROUP BY 1
ORDER BY 1;
