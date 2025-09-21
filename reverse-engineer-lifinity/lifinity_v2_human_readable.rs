// Lifinity V2 - Human Readable Solana Program
// Reverse-engineered from lifinity_v2.disasm
//
// This is a concentrated liquidity AMM (Automated Market Maker) with dynamic rebalancing
// It implements an enhanced constant product formula with concentration and inventory management

use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    msg,
    program::{invoke, invoke_signed},
    program_error::ProgramError,
    program_pack::Pack,
    pubkey::Pubkey,
    sysvar::{rent::Rent, Sysvar},
};
use borsh::{BorshDeserialize, BorshSerialize};
use pyth_sdk_solana::{Price, PriceFeed};

// Program IDs and Constants (extracted from bytecode)
const LIFINITY_PROGRAM_ID: [u8; 32] = [
    0x1c, 0xce, 0x98, 0x98, 0x35, 0x6d, 0xeb, 0x3f,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // ... (0x3feb6d359898ce1c)
];

const TOKEN_PROGRAM_ID: [u8; 32] = [
    0x2c, 0x34, 0x8d, 0xca, 0xa2, 0x40, 0x4f, 0x55,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // ... (0x554f40a2ca8d342c)
];

// ============================
// State Structures
// ============================

#[derive(BorshSerialize, BorshDeserialize, Debug, Clone)]
pub struct PoolState {
    // Basic pool info (offset 0-8)
    pub is_initialized: bool,              // offset 0: Pool initialization flag
    pub bump_seed: u8,                      // offset 1: PDA bump seed
    pub _padding1: [u8; 6],                 // padding

    // Concentration parameters (offset 8-24)
    pub concentration_factor: u64,          // offset 8: Liquidity concentration parameter (c)
    pub inventory_exponent: u64,            // offset 16: Inventory adjustment exponent (z)

    // Rebalancing parameters (offset 24-32)
    pub rebalance_threshold: u64,           // offset 24: V2 rebalance threshold (θ)

    // Token accounts (offset 32-160)
    pub token_a_mint: Pubkey,               // offset 32: Token A mint address
    pub token_b_mint: Pubkey,               // offset 64: Token B mint address
    pub token_a_vault: Pubkey,              // offset 96: Token A vault account
    pub token_b_vault: Pubkey,              // offset 128: Token B vault account

    // Oracle (offset 160-192)
    pub oracle_account: Pubkey,             // offset 160: Pyth oracle account

    // Reserves (offset 192-224)
    pub reserves_a: u64,                    // offset 192: Actual reserves of token A
    pub reserves_b: u64,                    // offset 200: Actual reserves of token B
    pub virtual_reserves_a: u64,            // offset 208: Virtual reserves A (concentrated)
    pub virtual_reserves_b: u64,            // offset 216: Virtual reserves B (concentrated)

    // Rebalancing state (offset 224-240)
    pub last_rebalance_price: u64,          // offset 224: Last rebalance reference price (p*)
    pub last_rebalance_slot: u64,           // offset 232: Slot of last rebalance

    // Fee configuration (offset 240-244)
    pub fee_numerator: u16,                 // offset 240: Fee numerator
    pub fee_denominator: u16,                // offset 242: Fee denominator

    // Statistics (offset 244-260)
    pub cumulative_fees_a: u64,             // offset 244: Cumulative fees in token A
    pub cumulative_fees_b: u64,             // offset 252: Cumulative fees in token B

    // Oracle config (offset 260-268)
    pub oracle_staleness_threshold: u64,    // offset 260: Max oracle age in slots

    // Authority (offset 268-300)
    pub authority: Pubkey,                  // offset 268: Pool authority/admin
}

// ============================
// Instruction Discriminators
// ============================

#[derive(BorshSerialize, BorshDeserialize, Debug)]
pub enum LifinityInstruction {
    // Initialize a new pool
    InitializePool {
        concentration_factor: u64,
        inventory_exponent: u64,
        rebalance_threshold: u64,
        fee_numerator: u16,
        fee_denominator: u16,
        oracle_staleness_threshold: u64,
    },

    // Swap with exact input amount
    SwapExactInput {
        amount_in: u64,
        minimum_amount_out: u64,
        is_base_input: bool, // true = token A input, false = token B input
    },

    // Swap with exact output amount
    SwapExactOutput {
        amount_out: u64,
        maximum_amount_in: u64,
        is_base_output: bool,
    },

    // Query pool state (view function)
    QueryPoolState,

    // V2 Rebalancing mechanism
    RebalanceV2,

    // Update concentration parameters (admin only)
    UpdateConcentration {
        new_concentration_factor: u64,
    },

    // Update inventory parameters (admin only)
    UpdateInventoryParams {
        new_inventory_exponent: u64,
        new_rebalance_threshold: u64,
    },
}

// ============================
// Entry Point
// ============================

entrypoint!(process_instruction);

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    msg!("Lifinity V2: Processing instruction");

    // The bytecode shows instruction routing based on discriminator
    // Lines 44-67 in disasm show the initial branching logic
    let instruction = LifinityInstruction::try_from_slice(instruction_data)?;

    match instruction {
        LifinityInstruction::InitializePool { .. } => {
            msg!("Initializing new pool");
            process_initialize_pool(program_id, accounts, instruction_data)
        }
        LifinityInstruction::SwapExactInput { .. } => {
            msg!("Processing swap with exact input");
            process_swap_exact_input(program_id, accounts, instruction_data)
        }
        LifinityInstruction::SwapExactOutput { .. } => {
            msg!("Processing swap with exact output");
            process_swap_exact_output(program_id, accounts, instruction_data)
        }
        LifinityInstruction::QueryPoolState => {
            msg!("Querying pool state");
            process_query_pool_state(program_id, accounts)
        }
        LifinityInstruction::RebalanceV2 => {
            msg!("Processing V2 rebalance");
            process_rebalance_v2(program_id, accounts)
        }
        LifinityInstruction::UpdateConcentration { .. } => {
            msg!("Updating concentration parameters");
            process_update_concentration(program_id, accounts, instruction_data)
        }
        LifinityInstruction::UpdateInventoryParams { .. } => {
            msg!("Updating inventory parameters");
            process_update_inventory_params(program_id, accounts, instruction_data)
        }
    }
}

// ============================
// Core Functions
// ============================

fn process_initialize_pool(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    // Extract accounts (pattern from lines 36-43 in disasm)
    let account_info_iter = &mut accounts.iter();
    let pool_account = next_account_info(account_info_iter)?;
    let authority = next_account_info(account_info_iter)?;
    let token_a_mint = next_account_info(account_info_iter)?;
    let token_b_mint = next_account_info(account_info_iter)?;
    let token_a_vault = next_account_info(account_info_iter)?;
    let token_b_vault = next_account_info(account_info_iter)?;
    let oracle_account = next_account_info(account_info_iter)?;
    let rent_sysvar = next_account_info(account_info_iter)?;

    // Parse instruction data
    let params = LifinityInstruction::try_from_slice(instruction_data)?;

    if let LifinityInstruction::InitializePool {
        concentration_factor,
        inventory_exponent,
        rebalance_threshold,
        fee_numerator,
        fee_denominator,
        oracle_staleness_threshold,
    } = params {
        // Initialize pool state in memory (pattern from lines 45-65)
        let mut pool_state = PoolState {
            is_initialized: true,
            bump_seed: 0, // Will be set from PDA derivation
            _padding1: [0; 6],
            concentration_factor,
            inventory_exponent,
            rebalance_threshold,
            token_a_mint: *token_a_mint.key,
            token_b_mint: *token_b_mint.key,
            token_a_vault: *token_a_vault.key,
            token_b_vault: *token_b_vault.key,
            oracle_account: *oracle_account.key,
            reserves_a: 0,
            reserves_b: 0,
            virtual_reserves_a: 0,
            virtual_reserves_b: 0,
            last_rebalance_price: 0,
            last_rebalance_slot: 0,
            fee_numerator,
            fee_denominator,
            cumulative_fees_a: 0,
            cumulative_fees_b: 0,
            oracle_staleness_threshold,
            authority: *authority.key,
        };

        // Save state to account
        pool_state.serialize(&mut &mut pool_account.data.borrow_mut()[..])?;

        msg!("Pool initialized successfully");
    }

    Ok(())
}

fn process_swap_exact_input(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    // Account extraction
    let account_info_iter = &mut accounts.iter();
    let pool_account = next_account_info(account_info_iter)?;
    let user_token_a = next_account_info(account_info_iter)?;
    let user_token_b = next_account_info(account_info_iter)?;
    let pool_token_a_vault = next_account_info(account_info_iter)?;
    let pool_token_b_vault = next_account_info(account_info_iter)?;
    let oracle_account = next_account_info(account_info_iter)?;
    let token_program = next_account_info(account_info_iter)?;

    // Load pool state
    let mut pool_state = PoolState::try_from_slice(&pool_account.data.borrow())?;

    // Parse swap parameters
    let params = LifinityInstruction::try_from_slice(instruction_data)?;

    if let LifinityInstruction::SwapExactInput {
        amount_in,
        minimum_amount_out,
        is_base_input,
    } = params {
        // Get oracle price (pattern from oracle calls in disasm)
        let oracle_price = get_oracle_price(oracle_account)?;

        // Calculate swap using concentrated liquidity formula
        let (amount_out, fee_amount) = calculate_swap_exact_input(
            &pool_state,
            amount_in,
            is_base_input,
            oracle_price,
        )?;

        // Check slippage
        if amount_out < minimum_amount_out {
            return Err(ProgramError::Custom(1)); // Slippage exceeded
        }

        // Update reserves based on swap direction
        if is_base_input {
            // A -> B swap
            pool_state.reserves_a += amount_in;
            pool_state.reserves_b -= amount_out;
            pool_state.virtual_reserves_a += amount_in;
            pool_state.virtual_reserves_b -= amount_out;
            pool_state.cumulative_fees_a += fee_amount;
        } else {
            // B -> A swap
            pool_state.reserves_b += amount_in;
            pool_state.reserves_a -= amount_out;
            pool_state.virtual_reserves_b += amount_in;
            pool_state.virtual_reserves_a -= amount_out;
            pool_state.cumulative_fees_b += fee_amount;
        }

        // Check if rebalancing is needed
        if should_rebalance(&pool_state, oracle_price) {
            perform_rebalance(&mut pool_state, oracle_price)?;
        }

        // Execute token transfers
        transfer_tokens(
            if is_base_input { user_token_a } else { user_token_b },
            if is_base_input { pool_token_a_vault } else { pool_token_b_vault },
            amount_in,
            token_program,
        )?;

        transfer_tokens(
            if is_base_input { pool_token_b_vault } else { pool_token_a_vault },
            if is_base_input { user_token_b } else { user_token_a },
            amount_out,
            token_program,
        )?;

        // Save updated state
        pool_state.serialize(&mut &mut pool_account.data.borrow_mut()[..])?;

        msg!("Swap executed: {} in -> {} out", amount_in, amount_out);
    }

    Ok(())
}

fn process_swap_exact_output(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    // Similar to exact input but calculates input from desired output
    // Implementation follows same pattern as exact input
    msg!("Processing exact output swap");

    // Account extraction and validation
    let account_info_iter = &mut accounts.iter();
    let pool_account = next_account_info(account_info_iter)?;
    // ... similar account extraction

    let mut pool_state = PoolState::try_from_slice(&pool_account.data.borrow())?;
    let params = LifinityInstruction::try_from_slice(instruction_data)?;

    if let LifinityInstruction::SwapExactOutput {
        amount_out,
        maximum_amount_in,
        is_base_output,
    } = params {
        let oracle_price = get_oracle_price(accounts.last().unwrap())?;

        // Calculate required input for exact output
        let (amount_in, fee_amount) = calculate_swap_exact_output(
            &pool_state,
            amount_out,
            is_base_output,
            oracle_price,
        )?;

        if amount_in > maximum_amount_in {
            return Err(ProgramError::Custom(2)); // Exceeds max input
        }

        // Update state and execute transfers (similar to exact input)
        // ...
    }

    Ok(())
}

fn process_query_pool_state(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
) -> ProgramResult {
    // Read-only function to return pool state
    let pool_account = &accounts[0];
    let pool_state = PoolState::try_from_slice(&pool_account.data.borrow())?;

    msg!("Pool State Query:");
    msg!("  Reserves A: {}", pool_state.reserves_a);
    msg!("  Reserves B: {}", pool_state.reserves_b);
    msg!("  Virtual Reserves A: {}", pool_state.virtual_reserves_a);
    msg!("  Virtual Reserves B: {}", pool_state.virtual_reserves_b);
    msg!("  Concentration Factor: {}", pool_state.concentration_factor);
    msg!("  Last Rebalance Price: {}", pool_state.last_rebalance_price);

    Ok(())
}

fn process_rebalance_v2(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
) -> ProgramResult {
    msg!("Processing V2 rebalance");

    let account_info_iter = &mut accounts.iter();
    let pool_account = next_account_info(account_info_iter)?;
    let oracle_account = next_account_info(account_info_iter)?;
    let authority = next_account_info(account_info_iter)?;

    let mut pool_state = PoolState::try_from_slice(&pool_account.data.borrow())?;

    // Check authority
    if authority.key != &pool_state.authority {
        return Err(ProgramError::Custom(3)); // Unauthorized
    }

    let oracle_price = get_oracle_price(oracle_account)?;

    // Check if rebalance is needed based on threshold
    if !should_rebalance(&pool_state, oracle_price) {
        msg!("Rebalance not needed");
        return Ok(());
    }

    // Perform rebalancing
    perform_rebalance(&mut pool_state, oracle_price)?;

    // Save state
    pool_state.serialize(&mut &mut pool_account.data.borrow_mut()[..])?;

    msg!("Rebalance completed at price: {}", oracle_price);
    Ok(())
}

fn process_update_concentration(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    // Admin function to update concentration parameters
    let account_info_iter = &mut accounts.iter();
    let pool_account = next_account_info(account_info_iter)?;
    let authority = next_account_info(account_info_iter)?;

    let mut pool_state = PoolState::try_from_slice(&pool_account.data.borrow())?;

    if authority.key != &pool_state.authority {
        return Err(ProgramError::Custom(4)); // Unauthorized
    }

    let params = LifinityInstruction::try_from_slice(instruction_data)?;

    if let LifinityInstruction::UpdateConcentration {
        new_concentration_factor,
    } = params {
        pool_state.concentration_factor = new_concentration_factor;

        // Recalculate virtual reserves with new concentration
        recalculate_virtual_reserves(&mut pool_state)?;

        pool_state.serialize(&mut &mut pool_account.data.borrow_mut()[..])?;
        msg!("Concentration factor updated to: {}", new_concentration_factor);
    }

    Ok(())
}

fn process_update_inventory_params(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    // Similar to update concentration but for inventory parameters
    let account_info_iter = &mut accounts.iter();
    let pool_account = next_account_info(account_info_iter)?;
    let authority = next_account_info(account_info_iter)?;

    let mut pool_state = PoolState::try_from_slice(&pool_account.data.borrow())?;

    if authority.key != &pool_state.authority {
        return Err(ProgramError::Custom(5)); // Unauthorized
    }

    let params = LifinityInstruction::try_from_slice(instruction_data)?;

    if let LifinityInstruction::UpdateInventoryParams {
        new_inventory_exponent,
        new_rebalance_threshold,
    } = params {
        pool_state.inventory_exponent = new_inventory_exponent;
        pool_state.rebalance_threshold = new_rebalance_threshold;

        pool_state.serialize(&mut &mut pool_account.data.borrow_mut()[..])?;
        msg!("Inventory params updated");
    }

    Ok(())
}

// ============================
// Helper Functions
// ============================

fn calculate_swap_exact_input(
    pool: &PoolState,
    amount_in: u64,
    is_base_input: bool,
    oracle_price: u64,
) -> Result<(u64, u64), ProgramError> {
    // Lifinity's concentrated liquidity formula with inventory management
    // This implements the modified constant product with concentration factor

    let fee_amount = (amount_in * pool.fee_numerator as u64) / pool.fee_denominator as u64;
    let amount_in_after_fee = amount_in - fee_amount;

    // Get current virtual reserves adjusted for concentration
    let (reserve_in, reserve_out) = if is_base_input {
        (pool.virtual_reserves_a, pool.virtual_reserves_b)
    } else {
        (pool.virtual_reserves_b, pool.virtual_reserves_a)
    };

    // Apply concentration factor to the swap calculation
    // k = x * y (constant product)
    // But with concentration: k = (x + c*Δx) * (y - Δy)
    let k = reserve_in * reserve_out;

    // Calculate output using concentrated liquidity formula
    let numerator = amount_in_after_fee * reserve_out;
    let denominator = reserve_in + amount_in_after_fee;
    let amount_out = numerator / denominator;

    // Apply inventory adjustment based on oracle price
    let inventory_adjusted_output = apply_inventory_adjustment(
        amount_out,
        pool.inventory_exponent,
        oracle_price,
        pool.last_rebalance_price,
    );

    Ok((inventory_adjusted_output, fee_amount))
}

fn calculate_swap_exact_output(
    pool: &PoolState,
    amount_out: u64,
    is_base_output: bool,
    oracle_price: u64,
) -> Result<(u64, u64), ProgramError> {
    // Inverse calculation for exact output swaps
    let (reserve_out, reserve_in) = if is_base_output {
        (pool.virtual_reserves_a, pool.virtual_reserves_b)
    } else {
        (pool.virtual_reserves_b, pool.virtual_reserves_a)
    };

    // Calculate required input for desired output
    let numerator = reserve_in * amount_out;
    let denominator = reserve_out - amount_out;

    if denominator == 0 {
        return Err(ProgramError::Custom(6)); // Insufficient liquidity
    }

    let amount_in_before_fee = numerator / denominator;

    // Calculate fee on top
    let fee_amount = (amount_in_before_fee * pool.fee_numerator as u64)
        / (pool.fee_denominator as u64 - pool.fee_numerator as u64);
    let total_amount_in = amount_in_before_fee + fee_amount;

    Ok((total_amount_in, fee_amount))
}

fn should_rebalance(pool: &PoolState, oracle_price: u64) -> bool {
    // Check if price has deviated beyond threshold
    if pool.last_rebalance_price == 0 {
        return true; // First rebalance
    }

    let price_change = if oracle_price > pool.last_rebalance_price {
        ((oracle_price - pool.last_rebalance_price) * 10000) / pool.last_rebalance_price
    } else {
        ((pool.last_rebalance_price - oracle_price) * 10000) / pool.last_rebalance_price
    };

    // Rebalance if price changed more than threshold (in basis points)
    price_change > pool.rebalance_threshold
}

fn perform_rebalance(pool: &mut PoolState, oracle_price: u64) -> Result<(), ProgramError> {
    // V2 rebalancing mechanism
    // Adjusts virtual reserves to align with oracle price while maintaining k

    let k = pool.virtual_reserves_a * pool.virtual_reserves_b;

    // Calculate new virtual reserves based on oracle price
    // Price = reserves_b / reserves_a, so:
    // reserves_a = sqrt(k / price)
    // reserves_b = sqrt(k * price)

    let sqrt_k = integer_sqrt(k);
    let sqrt_price = integer_sqrt(oracle_price);

    pool.virtual_reserves_a = sqrt_k * 10000 / sqrt_price;
    pool.virtual_reserves_b = sqrt_k * sqrt_price / 10000;

    pool.last_rebalance_price = oracle_price;
    pool.last_rebalance_slot = get_current_slot();

    msg!("Rebalanced: vA={}, vB={}", pool.virtual_reserves_a, pool.virtual_reserves_b);

    Ok(())
}

fn apply_inventory_adjustment(
    base_output: u64,
    inventory_exponent: u64,
    current_price: u64,
    reference_price: u64,
) -> u64 {
    // Apply inventory management adjustment
    // This encourages trades that move price toward oracle price

    if reference_price == 0 {
        return base_output;
    }

    let price_ratio = (current_price * 10000) / reference_price;

    // Apply exponential adjustment based on price deviation
    // If price is above reference, give better rates for selling
    // If price is below reference, give better rates for buying

    if price_ratio > 10000 {
        // Price above reference - encourage selling
        let adjustment = 10000 + ((price_ratio - 10000) * inventory_exponent / 10000);
        (base_output * adjustment) / 10000
    } else {
        // Price below reference - encourage buying
        let adjustment = 10000 - ((10000 - price_ratio) * inventory_exponent / 10000);
        (base_output * adjustment) / 10000
    }
}

fn recalculate_virtual_reserves(pool: &mut PoolState) -> Result<(), ProgramError> {
    // Recalculate virtual reserves based on new concentration factor
    // Virtual reserves = actual reserves * concentration factor

    pool.virtual_reserves_a = pool.reserves_a * pool.concentration_factor / 10000;
    pool.virtual_reserves_b = pool.reserves_b * pool.concentration_factor / 10000;

    Ok(())
}

fn get_oracle_price(oracle_account: &AccountInfo) -> Result<u64, ProgramError> {
    // Extract price from Pyth oracle account
    // In reality, this would deserialize the Pyth price feed

    // Simplified oracle price extraction
    let price_data = &oracle_account.data.borrow();

    // Pyth price is typically at a specific offset in the account data
    // This is a simplified representation
    let price = u64::from_le_bytes([
        price_data[0], price_data[1], price_data[2], price_data[3],
        price_data[4], price_data[5], price_data[6], price_data[7],
    ]);

    Ok(price)
}

fn transfer_tokens(
    from: &AccountInfo,
    to: &AccountInfo,
    amount: u64,
    token_program: &AccountInfo,
) -> Result<(), ProgramError> {
    // SPL Token transfer instruction
    let ix = spl_token::instruction::transfer(
        token_program.key,
        from.key,
        to.key,
        from.key, // Authority (simplified)
        &[],
        amount,
    )?;

    invoke(&ix, &[from.clone(), to.clone(), token_program.clone()])
}

fn integer_sqrt(n: u64) -> u64 {
    // Integer square root using Newton's method
    if n == 0 {
        return 0;
    }

    let mut x = n;
    let mut y = (x + 1) / 2;

    while y < x {
        x = y;
        y = (x + n / x) / 2;
    }

    x
}

fn get_current_slot() -> u64 {
    // In reality, this would get from Clock sysvar
    // Simplified for this representation
    0
}

// ============================
// Tests (if this were compiled)
// ============================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sqrt() {
        assert_eq!(integer_sqrt(0), 0);
        assert_eq!(integer_sqrt(1), 1);
        assert_eq!(integer_sqrt(4), 2);
        assert_eq!(integer_sqrt(100), 10);
        assert_eq!(integer_sqrt(1000000), 1000);
    }

    #[test]
    fn test_inventory_adjustment() {
        // Test price above reference
        let output = apply_inventory_adjustment(1000, 5000, 11000, 10000);
        assert!(output > 1000); // Should increase output

        // Test price below reference
        let output = apply_inventory_adjustment(1000, 5000, 9000, 10000);
        assert!(output < 1000); // Should decrease output

        // Test price at reference
        let output = apply_inventory_adjustment(1000, 5000, 10000, 10000);
        assert_eq!(output, 1000); // Should be unchanged
    }
}