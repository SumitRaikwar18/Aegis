module aegis::guardian;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{ID, UID};
use sui::tx_context::{Self, TxContext};

const E_NOT_OWNER: u64 = 0;
const E_EXPIRED: u64 = 1;
const E_AMOUNT_EXCEEDED: u64 = 2;
const E_SLIPPAGE_EXCEEDED: u64 = 3;
const E_POOL_NOT_ALLOWED: u64 = 4;
const E_REVOKED: u64 = 5;
const E_INVALID_DIRECTION: u64 = 6;

const DIRECTION_SUI_TO_DBUSDC: u8 = 0;
const DIRECTION_DBUSDC_TO_SUI: u8 = 1;

public struct GuardianPolicy has key, store {
    id: UID,
    owner: address,
    max_sui_input: u64,
    max_dbusdc_input: u64,
    max_slippage_bps: u64,
    allowed_pool: ID,
    expires_at_ms: u64,
    revoked: bool,
}

public struct IntentReceipt has key, store {
    id: UID,
    policy_id: ID,
    intent_hash: vector<u8>,
    pool: ID,
    direction: u8,
    input_amount: u64,
    min_output: u64,
    guardian_score: u8,
    verdict: String,
    executor: address,
    executed_at_ms: u64,
}

public struct PolicyCreated has copy, drop {
    policy_id: ID,
    owner: address,
    max_sui_input: u64,
    max_dbusdc_input: u64,
    max_slippage_bps: u64,
    allowed_pool: ID,
    expires_at_ms: u64,
}

public struct PolicyUpdated has copy, drop {
    policy_id: ID,
    owner: address,
    max_sui_input: u64,
    max_dbusdc_input: u64,
    max_slippage_bps: u64,
    expires_at_ms: u64,
}

public struct PolicyRevoked has copy, drop {
    policy_id: ID,
    owner: address,
    revoked_at_ms: u64,
}

public struct IntentExecuted has copy, drop {
    receipt_id: ID,
    policy_id: ID,
    executor: address,
    pool: ID,
    direction: u8,
    guardian_score: u8,
    verdict: String,
    input_amount: u64,
    min_output: u64,
    executed_at_ms: u64,
}

public fun create_policy(
    max_sui_input: u64,
    max_dbusdc_input: u64,
    max_slippage_bps: u64,
    allowed_pool: ID,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): GuardianPolicy {
    let owner = tx_context::sender(ctx);
    let policy = GuardianPolicy {
        id: object::new(ctx),
        owner,
        max_sui_input,
        max_dbusdc_input,
        max_slippage_bps,
        allowed_pool,
        expires_at_ms,
        revoked: false,
    };
    event::emit(PolicyCreated {
        policy_id: object::id(&policy),
        owner,
        max_sui_input,
        max_dbusdc_input,
        max_slippage_bps,
        allowed_pool,
        expires_at_ms,
    });
    policy
}

public fun update_policy(
    policy: &mut GuardianPolicy,
    max_sui_input: u64,
    max_dbusdc_input: u64,
    max_slippage_bps: u64,
    expires_at_ms: u64,
    ctx: &TxContext,
) {
    assert_owner(policy, ctx);
    assert!(!policy.revoked, E_REVOKED);
    policy.max_sui_input = max_sui_input;
    policy.max_dbusdc_input = max_dbusdc_input;
    policy.max_slippage_bps = max_slippage_bps;
    policy.expires_at_ms = expires_at_ms;
    event::emit(PolicyUpdated {
        policy_id: object::id(policy),
        owner: policy.owner,
        max_sui_input,
        max_dbusdc_input,
        max_slippage_bps,
        expires_at_ms,
    });
}

public fun revoke_policy(policy: &mut GuardianPolicy, clock: &Clock, ctx: &TxContext) {
    assert_owner(policy, ctx);
    policy.revoked = true;
    event::emit(PolicyRevoked {
        policy_id: object::id(policy),
        owner: policy.owner,
        revoked_at_ms: clock::timestamp_ms(clock),
    });
}

public fun assert_compliant(
    policy: &GuardianPolicy,
    direction: u8,
    amount: u64,
    requested_slippage_bps: u64,
    pool: ID,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_owner(policy, ctx);
    assert!(!policy.revoked, E_REVOKED);
    assert!(clock::timestamp_ms(clock) < policy.expires_at_ms, E_EXPIRED);
    assert!(requested_slippage_bps <= policy.max_slippage_bps, E_SLIPPAGE_EXCEEDED);
    assert!(pool == policy.allowed_pool, E_POOL_NOT_ALLOWED);
    if (direction == DIRECTION_SUI_TO_DBUSDC) {
        assert!(amount <= policy.max_sui_input, E_AMOUNT_EXCEEDED);
    } else if (direction == DIRECTION_DBUSDC_TO_SUI) {
        assert!(amount <= policy.max_dbusdc_input, E_AMOUNT_EXCEEDED);
    } else {
        abort E_INVALID_DIRECTION
    };
}

public fun mint_receipt(
    policy: &GuardianPolicy,
    intent_hash: vector<u8>,
    pool: ID,
    direction: u8,
    input_amount: u64,
    min_output: u64,
    guardian_score: u8,
    verdict: String,
    clock: &Clock,
    ctx: &mut TxContext,
): IntentReceipt {
    assert_owner(policy, ctx);
    assert!(!policy.revoked, E_REVOKED);
    assert!(pool == policy.allowed_pool, E_POOL_NOT_ALLOWED);
    let executor = tx_context::sender(ctx);
    let executed_at_ms = clock::timestamp_ms(clock);
    let policy_id = object::id(policy);
    let receipt = IntentReceipt {
        id: object::new(ctx),
        policy_id,
        intent_hash,
        pool,
        direction,
        input_amount,
        min_output,
        guardian_score,
        verdict,
        executor,
        executed_at_ms,
    };
    event::emit(IntentExecuted {
        receipt_id: object::id(&receipt),
        policy_id,
        executor,
        pool,
        direction,
        guardian_score,
        verdict: copy verdict,
        input_amount,
        min_output,
        executed_at_ms,
    });
    receipt
}

fun assert_owner(policy: &GuardianPolicy, ctx: &TxContext) {
    assert!(policy.owner == tx_context::sender(ctx), E_NOT_OWNER);
}

#[test_only]
fun test_context(sender: address, hint: u64): TxContext {
    tx_context::new_from_hint(sender, hint, 0, 0, 0)
}

#[test_only]
fun test_policy(ctx: &mut TxContext): GuardianPolicy {
    create_policy(
        5_000_000_000,
        10_000_000,
        200,
        object::id_from_address(@0x4405),
        10_000,
        ctx,
    )
}

#[test_only]
fun destroy_policy(policy: GuardianPolicy) {
    let GuardianPolicy {
        id,
        owner: _,
        max_sui_input: _,
        max_dbusdc_input: _,
        max_slippage_bps: _,
        allowed_pool: _,
        expires_at_ms: _,
        revoked: _,
    } = policy;
    object::delete(id);
}

#[test_only]
fun destroy_receipt(receipt: IntentReceipt) {
    let IntentReceipt {
        id,
        policy_id: _,
        intent_hash: _,
        pool: _,
        direction: _,
        input_amount: _,
        min_output: _,
        guardian_score: _,
        verdict: _,
        executor: _,
        executed_at_ms: _,
    } = receipt;
    object::delete(id);
}

#[test]
fun test_create_update_revoke_policy() {
    let mut ctx = test_context(@0xCAFE, 1);
    let clock = clock::create_for_testing(&mut ctx);
    let mut policy = test_policy(&mut ctx);
    update_policy(&mut policy, 4_000_000_000, 8_000_000, 150, 20_000, &ctx);
    assert!(policy.max_sui_input == 4_000_000_000);
    assert!(policy.max_dbusdc_input == 8_000_000);
    assert!(policy.max_slippage_bps == 150);
    revoke_policy(&mut policy, &clock, &ctx);
    assert!(policy.revoked);
    destroy_policy(policy);
    clock.destroy_for_testing();
}

#[test]
fun test_valid_sui_and_dbusdc_trades_and_receipt() {
    let mut ctx = test_context(@0xCAFE, 2);
    let clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    let pool = object::id_from_address(@0x4405);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 1_000_000_000, 100, pool, &clock, &ctx);
    assert_compliant(&policy, DIRECTION_DBUSDC_TO_SUI, 5_000_000, 100, pool, &clock, &ctx);
    let receipt = mint_receipt(
        &policy,
        b"swap 1 sui",
        pool,
        DIRECTION_SUI_TO_DBUSDC,
        1_000_000_000,
        700_000,
        22,
        b"clear".to_string(),
        &clock,
        &mut ctx,
    );
    destroy_receipt(receipt);
    destroy_policy(policy);
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = E_NOT_OWNER)]
fun test_wrong_owner_rejected() {
    let mut owner_ctx = test_context(@0xCAFE, 3);
    let clock = clock::create_for_testing(&mut owner_ctx);
    let policy = test_policy(&mut owner_ctx);
    let attacker_ctx = test_context(@0xDEAD, 4);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 1, 100, object::id_from_address(@0x4405), &clock, &attacker_ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_EXPIRED)]
fun test_expired_policy_rejected() {
    let mut ctx = test_context(@0xCAFE, 5);
    let mut clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    clock.set_for_testing(10_001);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 1, 100, object::id_from_address(@0x4405), &clock, &ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_REVOKED)]
fun test_revoked_policy_rejected() {
    let mut ctx = test_context(@0xCAFE, 6);
    let clock = clock::create_for_testing(&mut ctx);
    let mut policy = test_policy(&mut ctx);
    revoke_policy(&mut policy, &clock, &ctx);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 1, 100, object::id_from_address(@0x4405), &clock, &ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_AMOUNT_EXCEEDED)]
fun test_sui_ceiling_enforced() {
    let mut ctx = test_context(@0xCAFE, 7);
    let clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 5_000_000_001, 100, object::id_from_address(@0x4405), &clock, &ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_AMOUNT_EXCEEDED)]
fun test_dbusdc_ceiling_enforced() {
    let mut ctx = test_context(@0xCAFE, 8);
    let clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    assert_compliant(&policy, DIRECTION_DBUSDC_TO_SUI, 10_000_001, 100, object::id_from_address(@0x4405), &clock, &ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_SLIPPAGE_EXCEEDED)]
fun test_slippage_enforced() {
    let mut ctx = test_context(@0xCAFE, 9);
    let clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 1, 201, object::id_from_address(@0x4405), &clock, &ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_POOL_NOT_ALLOWED)]
fun test_pool_enforced() {
    let mut ctx = test_context(@0xCAFE, 10);
    let clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    assert_compliant(&policy, DIRECTION_SUI_TO_DBUSDC, 1, 100, object::id_from_address(@0x9999), &clock, &ctx);
    abort 99
}

#[test, expected_failure(abort_code = E_INVALID_DIRECTION)]
fun test_direction_enforced() {
    let mut ctx = test_context(@0xCAFE, 11);
    let clock = clock::create_for_testing(&mut ctx);
    let policy = test_policy(&mut ctx);
    assert_compliant(&policy, 2, 1, 100, object::id_from_address(@0x4405), &clock, &ctx);
    abort 99
}
