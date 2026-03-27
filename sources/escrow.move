module sui_inpact::escrow;

use sui::clock::{Self, Clock};
use sui::event;

const PCT_DENOMINATOR: u64 = 100;

const E_INVALID_STATUS: u64 = 3;
const E_JOIN_EXPIRED: u64 = 4;
const E_INVALID_AMOUNT: u64 = 7;
const E_MUTUAL_APPROVAL_NOT_BOTH: u64 = 9;
const E_MUTUAL_APPROVAL_MISMATCH: u64 = 10;
const E_INVALID_SPLIT_PCT: u64 = 11;
const E_ALREADY_JOINED: u64 = 13;
const E_INVALID_PROOF: u64 = 15;
const E_MISSING_COMMITMENT: u64 = 16;

const PROOF_FUNDING: u8 = 1;
const PROOF_RELEASE: u8 = 2;
const PROOF_SPLIT: u8 = 3;
const PROOF_REFUND: u8 = 4;
const ROLE_BUYER: u8 = 1;
const ROLE_DEVELOPER: u8 = 2;

public enum Status has copy, drop, store {
    Draft,
    Partially_Funded,
    Fully_Funded,
    Resolving,
    Verification_Passed,
    Mutual_Released,
    Refund_Unmatched,
    Settled_Split,
    Released,
}

public struct PaymentProof has copy, drop, store {
    kind: u8,
    amount: u64,
    ciphertext: vector<u8>,
    recorded_at_ms: u64,
}

public struct OperatorCap has key, store {
    id: UID,
}

public struct Escrow has key {
    id: UID,
    status: Status,
    buyer_commitment: vector<u8>,
    developer_commitment: vector<u8>,
    developer_joined: bool,
    amount: u64,
    created_at_ms: u64,
    join_expiry_ms: u64,
    agreement_uri_or_hash: vector<u8>,
    claimed_buyer: bool,
    claimed_developer: bool,
    mutual_release_approved_buyer: bool,
    mutual_release_approved_developer: bool,
    mutual_split_proposal_buyer: Option<u64>,
    mutual_split_proposal_developer: Option<u64>,
    settlement_buyer_share_pct: Option<u64>,
    payment_proofs: vector<PaymentProof>,
}

public struct EscrowCreated has copy, drop {
    escrow_id: ID,
    amount: u64,
    join_expiry_ms: u64,
}

public struct BuyerFunded has copy, drop {
    escrow_id: ID,
    amount: u64,
}

public struct DeveloperJoined has copy, drop {
    escrow_id: ID,
}

public struct RefundUnmatched has copy, drop {
    escrow_id: ID,
}

public struct VerificationPassed has copy, drop {
    escrow_id: ID,
}

public struct MutualReleaseApproved has copy, drop {
    escrow_id: ID,
    role: u8,
}

public struct MutualReleased has copy, drop {
    escrow_id: ID,
}

public struct MutualSplitProposed has copy, drop {
    escrow_id: ID,
    role: u8,
    buyer_share_pct: u64,
}

public struct SplitSettled has copy, drop {
    escrow_id: ID,
    buyer_share_pct: u64,
}

public struct PaymentProofRecorded has copy, drop {
    escrow_id: ID,
    proof_kind: u8,
    amount: u64,
    recorded_at_ms: u64,
}

fun escrow_id(escrow: &Escrow): ID {
    object::id(escrow)
}

fun is_status(escrow: &Escrow, status: Status): bool {
    escrow.status == status
}

fun assert_status(escrow: &Escrow, status: Status, err: u64) {
    assert!(is_status(escrow, status), err);
}

fun assert_operator(_cap: &OperatorCap, _ctx: &TxContext) {
}

fun assert_valid_split_pct(buyer_share_pct: u64) {
    assert!(buyer_share_pct <= PCT_DENOMINATOR, E_INVALID_SPLIT_PCT);
}

fun has_joined(escrow: &Escrow): bool {
    escrow.developer_joined
}

fun reset_mutual_release(escrow: &mut Escrow) {
    escrow.mutual_release_approved_buyer = false;
    escrow.mutual_release_approved_developer = false;
}

fun reset_mutual_split(escrow: &mut Escrow) {
    escrow.mutual_split_proposal_buyer = option::none();
    escrow.mutual_split_proposal_developer = option::none();
    escrow.settlement_buyer_share_pct = option::none();
}

fun clear_all_proposals(escrow: &mut Escrow) {
    reset_mutual_release(escrow);
    reset_mutual_split(escrow);
}

fun move_to_resolving(escrow: &mut Escrow) {
    if (is_status(escrow, Status::Fully_Funded)) {
        escrow.status = Status::Resolving;
    } else {
        assert_status(escrow, Status::Resolving, E_INVALID_STATUS);
    }
}

fun record_payment_proof(
    escrow: &mut Escrow,
    proof_kind: u8,
    amount: u64,
    ciphertext: vector<u8>,
    recorded_at_ms: u64,
) {
    assert!(amount > 0, E_INVALID_AMOUNT);
    assert!(vector::length(&ciphertext) > 0, E_INVALID_PROOF);
    vector::push_back(&mut escrow.payment_proofs, PaymentProof {
        kind: proof_kind,
        amount,
        ciphertext,
        recorded_at_ms,
    });
    event::emit(PaymentProofRecorded {
        escrow_id: escrow_id(escrow),
        proof_kind,
        amount,
        recorded_at_ms,
    });
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        OperatorCap { id: object::new(ctx) },
        tx_context::sender(ctx),
    );
}

public fun create_draft(
    cap: &OperatorCap,
    buyer_commitment: vector<u8>,
    developer_commitment: vector<u8>,
    amount: u64,
    join_expiry_ms: u64,
    agreement_uri_or_hash: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert_operator(cap, ctx);
    let now_ms = clock::timestamp_ms(clock);
    assert!(amount > 0, E_INVALID_AMOUNT);
    assert!(vector::length(&buyer_commitment) > 0, E_MISSING_COMMITMENT);
    assert!(vector::length(&developer_commitment) > 0, E_MISSING_COMMITMENT);

    let escrow = Escrow {
        id: object::new(ctx),
        status: Status::Draft,
        buyer_commitment,
        developer_commitment,
        developer_joined: false,
        amount,
        created_at_ms: now_ms,
        join_expiry_ms,
        agreement_uri_or_hash,
        claimed_buyer: false,
        claimed_developer: false,
        mutual_release_approved_buyer: false,
        mutual_release_approved_developer: false,
        mutual_split_proposal_buyer: option::none(),
        mutual_split_proposal_developer: option::none(),
        settlement_buyer_share_pct: option::none(),
        payment_proofs: vector::empty(),
    };

    event::emit(EscrowCreated {
        escrow_id: escrow_id(&escrow),
        amount,
        join_expiry_ms,
    });

    transfer::share_object(escrow);
}

public fun record_funding_proof(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    amount: u64,
    ciphertext: vector<u8>,
    clock: &Clock,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_status(escrow, Status::Draft, E_INVALID_STATUS);
    assert!(amount == escrow.amount, E_INVALID_AMOUNT);
    record_payment_proof(
        escrow,
        PROOF_FUNDING,
        amount,
        ciphertext,
        clock::timestamp_ms(clock)
    );
    escrow.status = Status::Partially_Funded;
    escrow.claimed_buyer = false;
    escrow.claimed_developer = false;
    clear_all_proposals(escrow);

    event::emit(BuyerFunded {
        escrow_id: escrow_id(escrow),
        amount,
    });
}

public fun join_as_developer(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    clock: &Clock,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_status(escrow, Status::Partially_Funded, E_INVALID_STATUS);
    let now_ms = clock::timestamp_ms(clock);
    assert!(now_ms <= escrow.join_expiry_ms, E_JOIN_EXPIRED);
    assert!(vector::length(&escrow.developer_commitment) > 0, E_MISSING_COMMITMENT);
    assert!(!has_joined(escrow), E_ALREADY_JOINED);

    escrow.developer_joined = true;
    escrow.status = Status::Fully_Funded;
    clear_all_proposals(escrow);

    event::emit(DeveloperJoined {
        escrow_id: escrow_id(escrow),
    });
}

public fun refund_unmatched(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    clock: &Clock,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_status(escrow, Status::Partially_Funded, E_INVALID_STATUS);
    assert!(clock::timestamp_ms(clock) > escrow.join_expiry_ms, E_JOIN_EXPIRED);
    escrow.status = Status::Refund_Unmatched;
    clear_all_proposals(escrow);
    event::emit(RefundUnmatched {
        escrow_id: escrow_id(escrow),
    });
}

public fun mark_verification_passed(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_status(escrow, Status::Fully_Funded, E_INVALID_STATUS);
    assert!(has_joined(escrow), E_ALREADY_JOINED);
    escrow.status = Status::Verification_Passed;
    clear_all_proposals(escrow);
    event::emit(VerificationPassed {
        escrow_id: escrow_id(escrow),
    });
}

public fun approve_mutual_release_buyer(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    move_to_resolving(escrow);
    escrow.mutual_release_approved_buyer = true;
    reset_mutual_split(escrow);
    event::emit(MutualReleaseApproved {
        escrow_id: escrow_id(escrow),
        role: ROLE_BUYER,
    });
}

public fun approve_mutual_release_developer(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    move_to_resolving(escrow);
    assert!(has_joined(escrow), E_ALREADY_JOINED);
    escrow.mutual_release_approved_developer = true;
    reset_mutual_split(escrow);
    event::emit(MutualReleaseApproved {
        escrow_id: escrow_id(escrow),
        role: ROLE_DEVELOPER,
    });
}

public fun finalize_mutual_release(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_status(escrow, Status::Resolving, E_INVALID_STATUS);
    assert!(
        escrow.mutual_release_approved_buyer && escrow.mutual_release_approved_developer,
        E_MUTUAL_APPROVAL_NOT_BOTH
    );
    escrow.status = Status::Mutual_Released;
    reset_mutual_release(escrow);
    reset_mutual_split(escrow);
    event::emit(MutualReleased {
        escrow_id: escrow_id(escrow),
    });
}

public fun propose_mutual_split_buyer(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    buyer_share_pct: u64,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_valid_split_pct(buyer_share_pct);
    move_to_resolving(escrow);
    escrow.mutual_split_proposal_buyer = option::some(buyer_share_pct);
    escrow.mutual_split_proposal_developer = option::none();
    reset_mutual_release(escrow);
    event::emit(MutualSplitProposed {
        escrow_id: escrow_id(escrow),
        role: ROLE_BUYER,
        buyer_share_pct,
    });
}

public fun approve_mutual_split_developer(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    buyer_share_pct: u64,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_valid_split_pct(buyer_share_pct);
    move_to_resolving(escrow);
    assert!(has_joined(escrow), E_ALREADY_JOINED);
    assert!(option::is_some(&escrow.mutual_split_proposal_buyer), E_MUTUAL_APPROVAL_NOT_BOTH);
    assert!(*option::borrow(&escrow.mutual_split_proposal_buyer) == buyer_share_pct, E_MUTUAL_APPROVAL_MISMATCH);
    escrow.mutual_split_proposal_developer = option::some(buyer_share_pct);
    escrow.settlement_buyer_share_pct = option::some(buyer_share_pct);
    escrow.status = Status::Settled_Split;
    reset_mutual_release(escrow);
    event::emit(MutualSplitProposed {
        escrow_id: escrow_id(escrow),
        role: ROLE_DEVELOPER,
        buyer_share_pct,
    });
    event::emit(SplitSettled {
        escrow_id: escrow_id(escrow),
        buyer_share_pct,
    });
}

public fun record_release_proof(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    amount: u64,
    ciphertext: vector<u8>,
    clock: &Clock,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert!(is_status(escrow, Status::Verification_Passed) || is_status(escrow, Status::Mutual_Released), E_INVALID_STATUS);
    assert!(amount == escrow.amount, E_INVALID_AMOUNT);
    record_payment_proof(
        escrow,
        PROOF_RELEASE,
        amount,
        ciphertext,
        clock::timestamp_ms(clock)
    );
    escrow.claimed_developer = true;
    escrow.status = Status::Released;
}

public fun record_refund_proof(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    amount: u64,
    ciphertext: vector<u8>,
    clock: &Clock,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert!(is_status(escrow, Status::Refund_Unmatched) || is_status(escrow, Status::Partially_Funded), E_INVALID_STATUS);
    assert!(amount == escrow.amount, E_INVALID_AMOUNT);
    record_payment_proof(
        escrow,
        PROOF_REFUND,
        amount,
        ciphertext,
        clock::timestamp_ms(clock)
    );
    escrow.claimed_buyer = true;
    escrow.status = Status::Released;
}

public fun record_split_proof(
    cap: &OperatorCap,
    escrow: &mut Escrow,
    buyer_share_pct: u64,
    amount: u64,
    ciphertext: vector<u8>,
    clock: &Clock,
    ctx: &TxContext
) {
    assert_operator(cap, ctx);
    assert_valid_split_pct(buyer_share_pct);
    assert!(is_status(escrow, Status::Settled_Split), E_INVALID_STATUS);
    assert!(amount == escrow.amount, E_INVALID_AMOUNT);
    escrow.settlement_buyer_share_pct = option::some(buyer_share_pct);
    record_payment_proof(
        escrow,
        PROOF_SPLIT,
        amount,
        ciphertext,
        clock::timestamp_ms(clock)
    );
    escrow.claimed_buyer = true;
    escrow.claimed_developer = true;
    escrow.status = Status::Released;
}
