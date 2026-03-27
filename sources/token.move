module sui_inpact::inpact_token;

use sui::coin::{Self, TreasuryCap};
use sui::coin_registry;

/// Payment token used by the SuiInpact escrow contract.
public struct INPACT_TOKEN has drop {}

/// Initializes the token, freezes metadata, and transfers the treasury cap
/// to the publisher.
fun init(witness: INPACT_TOKEN, ctx: &mut TxContext) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"INPACT".to_string(),
        b"SuiInpact Token".to_string(),
        b"Payment token for SuiInpact escrow settlements".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}

/// Mints tokens and transfers them to the requested recipient.
public fun mint(
    treasury_cap: &mut TreasuryCap<INPACT_TOKEN>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    let minted = coin::mint(treasury_cap, amount, ctx);
    transfer::public_transfer(minted, recipient);
}
