// Internals of the AMM

%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_nn_le, assert_nn, assert_le
from starkware.starknet.common.syscalls import get_block_timestamp
from math64x61 import Math64x61

from contracts.constants import (
    VOLATILITY_LOWER_BOUND,
    VOLATILITY_UPPER_BOUND,
    OPTION_CALL,
    OPTION_PUT,
    TRADE_SIDE_LONG,
    TRADE_SIDE_SHORT,
    RISK_FREE_RATE,
    STOP_TRADING_BEFORE_MATURITY_SECONDS,
    EMPIRIC_ETH_USD_KEY
)
from contracts.fees import get_fees
from contracts.interface_liquidity_pool import ILiquidityPool
from contracts.option_pricing import black_scholes
from contracts.oracles import empiric_median_price
from contracts.types import (Bool, Wad, Math64x61_, OptionType, OptionSide, Int, Address)



// Stores current value of volatility for given pool (option type) and maturity.
@storage_var
func pool_volatility(pool_address: Address, maturity: Int) -> (volatility: Math64x61_) {
}


@storage_var
func pool_address_for_given_asset_and_option_type(asset: felt, option_type: OptionType) -> (
    address: Address
) {
}


// ############################
// storage_var handlers
// ############################


@view
func get_pool_volatility{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pool_address: Address, maturity: Int
) -> (pool_volatility: Math64x61_) {
    let (pool_volatility_) = pool_volatility.read(pool_address, maturity);
    return (pool_volatility_,);
}


func set_pool_volatility{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pool_address: Address, maturity: Int, volatility: Math64x61_
) {
    // volatility has to be above 1 (in terms of Math64x61.FRACT_PART units...
    // ie volatility = 1 is very very close to 0 and 100% volatility would be
    // volatility=Math64x61.FRACT_PART)
    assert_nn_le(volatility, VOLATILITY_UPPER_BOUND - 1);
    assert_nn_le(VOLATILITY_LOWER_BOUND, volatility);
    pool_volatility.write(pool_address, maturity, volatility);
    return ();
}


@external
func set_pool_address_for_given_asset_and_option_type{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    asset: felt, option_type: OptionType, pool_address: Address
) {
    // FIXME: @svetylko
}


// ############################
// Pool information handlers
// ############################

// FIXME: available options are set in contracts/liquidity_pool.cairo since it contains storage_var for it

@view
func get_pool_available_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    option_type: OptionType
) -> (pool_balance: felt) {
    // Returns total locked capital in the pool minus the locked capital
    // (ie capital available to locking).
    // FIXME: get this information from liquidity pool
    return (pool_balance_)
}


@view
func get_available_options{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    underlying_asset: felt, option_type: OptionType, strike_price: Math64x61_, maturity: Int
) -> (option_availability: felt) {
    // FIXME: get this information from liquidity pool
    let (option_availability_) = available_options.read(option_type, strike_price, maturity);
    return (option_availability_,);
}


// ############################
// AMM logic - helpers
// ############################

func _select_and_adjust_premia{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    call_premia: Math64x61_,
    put_premia: Math64x61_,
    option_type: OptionType,
    underlying_price: Math64x61_
) -> (premia: Math64x61_) {
    // Call and Put premia on input are in quote tokens (in USDC in case of ETH/USDC)
    // This function puts them into their respective currency
    // (and selects the premia based on option_type)
    //  - call premia into base token (ETH in case of ETH/USDC)
    //  - put premia stays the same, ie in quote tokens (USDC in case of ETH/USDC)

    assert (option_type - OPTION_CALL) * (option_type - OPTION_PUT) = 0;

    if (option_type == OPTION_CALL) {
        let (adjusted_call_premia) = Math64x61.div(call_premia, underlying_price);
        return (premia=adjusted_call_premia);
    }
    return (premia=put_premia);
}


func _time_till_maturity{syscall_ptr: felt*, range_check_ptr}(maturity: Int) -> (
    time_till_maturity: Math64x61_
) {
    // Calculates time till maturity in terms of Math64x61 type
    // Inputted maturity if not in the same type -> has to converted... and it is number
    // of seconds corresponding to unix timestamp

    alloc_locals;
    local syscall_ptr: felt* = syscall_ptr;  // Reference revoked fix

    let (currtime) = get_block_timestamp();  // is number of seconds... unix timestamp
    let (currtime_math) = Math64x61.fromFelt(currtime);
    let (maturity_math) = Math64x61.fromFelt(maturity);
    let (secs_in_year) = Math64x61.fromFelt(60 * 60 * 24 * 365);

    let (secs_left) = Math64x61.sub(maturity_math, currtime_math);
    assert_nn(secs_left);

    let (time_till_maturity) = Math64x61.div(secs_left, secs_in_year);
    return (time_till_maturity,);
}


func _add_premia_fees{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    side: OptionSide, total_premia_before_fees: Math64x61_, total_fees: Math64x61_
) -> (total_premia: Math64x61_) {
    // Sums fees and premia... in case of long = premia+fees, short = premia-fees

    assert (side - TRADE_SIDE_SHORT) * (side - TRADE_SIDE_LONG) = 0;

    // if side == TRADE_SIDE_LONG (user pays premia) the fees are added on top of premia
    // if side == TRADE_SIDE_SHORT (user receives premia) the fees are subtracted from the premia
    if (side == TRADE_SIDE_LONG) {
        let (premia_fees_add) = Math64x61.add(total_premia_before_fees, total_fees);
        return (premia_fees_add,);
    }
    let (premia_fees_sub) = Math64x61.sub(total_premia_before_fees, total_fees);
    return (premia_fees_sub,);
}

func _get_vol_update_denominator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    relative_option_size: Math64x61_, side: OptionSide
) -> (relative_option_size: Math64x61_) {
    if (side == TRADE_SIDE_LONG) {
        let (long_denominator) = Math64x61.sub(Math64x61.ONE, relative_option_size);
        return (long_denominator,);
    }
    let (short_denominator) = Math64x61.add(Math64x61.ONE, relative_option_size);
    return (short_denominator,);
}

func _get_new_volatility{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    current_volatility: Math64x61_,
    option_size: Math64x61_,
    option_type: OptionType,
    side: OptionSide,
    underlying_price: Math64x61_,
) -> (new_volatility: Math64x61_, trade_volatility: Math64x61_) {
    // Calculates two volatilities, one for trade that is happening
    // and the other to update the volatility param (storage_var).
    // Docs are here
    // https://carmine-finance.gitbook.io/carmine-options-amm/mechanics-deeper-look/option-pricing-mechanics#volatility-updates

    alloc_locals;

    let (option_size_in_pool_currency) = _get_option_size_in_pool_currency(
        option_size, option_type, underlying_price
    );

    let (current_pool_balance) = get_pool_available_balance(option_type);
    assert_nn_le(Math64x61.ONE, current_pool_balance);
    assert_nn_le(option_size_in_pool_currency, current_pool_balance);
    let (relative_option_size) = Math64x61.div(option_size_in_pool_currency, current_pool_balance);

    // alpha – rate of change assumed to be 1
    let (denominator) = _get_vol_update_denominator(relative_option_size, side);
    let (volatility_scale) = Math64x61.div(Math64x61.ONE, denominator);
    let (new_volatility) = Math64x61.mul(current_volatility, volatility_scale);

    let (volsum) = Math64x61.add(current_volatility, new_volatility);
    let (two) = Math64x61.fromFelt(2);
    let (trade_volatility) = Math64x61.div(volsum, two);

    return (new_volatility=new_volatility, trade_volatility=trade_volatility);
}


func get_empiric_key{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    underlying_asset: felt
) -> (empiric_key: felt) {
    return (EMPIRIC_ETH_USD_KEY,)
}


func do_trade{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    option_type: OptionType,
    strike_price: Math64x61_,
    maturity: Int,
    side: OptionSide,
    option_size: Math64x61_,
    underlying_asset: felt
) -> (premia: Math64x61_) {
    // options_size is always denominated in base tokens (ETH in case of ETH/USDC)

    alloc_locals;

    // 0) Get pool address
    let (pool_address) = pool_address_for_given_asset_and_option_type.read(
        underlying_asset,
        option_type
    );

    // 1) Get current volatility
    let (current_volatility) = get_pool_volatility(pool_address, maturity);

    // 2) Get price of underlying asset
    let (empiric_key) = get_empiric_key(underlying_asset)
    let (underlying_price) = empiric_median_price(empiric_key);

    // 3) Calculate new volatility, calculate trade volatilit
    let (new_volatility, trade_volatility) = _get_new_volatility(
        current_volatility, option_size, option_type, side, underlying_price
    );

    // 4) Update volatility
    set_pool_volatility(pool_address, maturity, new_volatility);

    // 5) Get time till maturity
    let (time_till_maturity) = _time_till_maturity(maturity);

    // 6) risk free rate
    let (risk_free_rate_annualized) = RISK_FREE_RATE;

    // 7) Get premia
    // call_premia, put_premia in quote tokens (USDC in case of ETH/USDC)
    let (call_premia, put_premia) = black_scholes(
        sigma=trade_volatility,
        time_till_maturity_annualized=time_till_maturity,
        strike_price=strike_price,
        underlying_price=underlying_price,
        risk_free_rate_annualized=risk_free_rate_annualized,
    );
    // AFTER THE LINE BELOW, THE PREMIA IS IN TERMS OF CORRESPONDING POOL
    // Ie in case of call option, the premia is in base (ETH in case ETH/USDC)
    // and in quote tokens (USDC in case of ETH/USDC) for put option.
    let (premia) = _select_and_adjust_premia(
        call_premia, put_premia, option_type, underlying_price
    );
    // premia adjusted by size (multiplied by size)
    let (total_premia_before_fees) = Math64x61.mul(premia, option_size);

    // 8) Get fees
    // fees are already in the currency same as premia
    // if side == TRADE_SIDE_LONG (user pays premia) the fees are added on top of premia
    // if side == TRADE_SIDE_SHORT (user receives premia) the fees are substracted from the premia
    let (total_fees) = get_fees(total_premia_before_fees);
    let (total_premia) = _add_premia_fees(side, total_premia_before_fees, total_fees);

    // 9) Make the trade

    // FIXME: consider dropping the option_token_address and finding it inside of the liquidity_pool.mint_option_token
    let (option_token_address) = ILiquidityPool.get_option_token_address(
        contract_address=pool_address,
        option_side=side,
        option_type=option_type,
        maturity=maturity,
        strike_price=strike_price
    );
    // FIXME: switch from separate premia and fees to using combined number here
    ILiquidityPool.mint_option_token(
        contract_address=pool_address,
        option_token_address=option_token_address,
        amount=option_size,
        option_side=side,
        option_type=option_type,
        maturity=maturity,
        strike=strike_price,
        premia=total_premia_before_fees,
        fees=total_fees,
        underlying_price=underlying_price,
    );

    return (premia=premia);
}

func close_position{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    option_type : OptionType,
    strike_price : Math64x61_,
    maturity : felt,
    side : felt,
    option_size : felt,
    underlying_asset: felt,
    open_position: felt,
) -> (premia : felt) {
    // All of the unlocking of capital happens inside of the burn function below.
    // Volatility is not updated since closing position is considered as
    // "user does not have opinion on the market state" - this may change down the line

    alloc_locals;

    // 0) Get pool address
    let (pool_address) = pool_address_for_given_asset_and_option_type.read(
        underlying_asset,
        option_type
    );

    // 1) Get current volatility
    let (current_volatility) = get_pool_volatility(pool_address, maturity);

    // 2) Get price of underlying asset
    let (empiric_key) = get_empiric_key(underlying_asset)
    let (underlying_price) = empiric_median_price(empiric_key);

    // 3) Calculate new volatility, calculate trade volatilit
    let (new_volatility, trade_volatility) = _get_new_volatility(
        current_volatility, option_size, option_type, side, underlying_price
    );

    // 4) Update volatility
    // Update volatility does not happen in this function - look at docstring

    // 5) Get time till maturity
    let (time_till_maturity) = _time_till_maturity(maturity);

    // 6) risk free rate
    let (risk_free_rate_annualized) = RISK_FREE_RATE;

    // 7) Get premia
    // call_premia, put_premia in quote tokens (USDC in case of ETH/USDC)
    let (call_premia, put_premia) = black_scholes(
        sigma=trade_volatility,
        time_till_maturity_annualized=time_till_maturity,
        strike_price=strike_price,
        underlying_price=underlying_price,
        risk_free_rate_annualized=risk_free_rate_annualized,
    );
    // AFTER THE LINE BELOW, THE PREMIA IS IN TERMS OF CORRESPONDING POOL
    // Ie in case of call option, the premia is in base (ETH in case ETH/USDC)
    // and in quote tokens (USDC in case of ETH/USDC) for put option.
    let (premia) = _select_and_adjust_premia(
        call_premia, put_premia, option_type, underlying_price
    );
    // premia adjusted by size (multiplied by size)
    let (total_premia_before_fees) = Math64x61.mul(premia, option_size);

    // 8) Get fees
    // fees are already in the currency same as premia
    // if side == TRADE_SIDE_LONG (user pays premia) the fees are added on top of premia
    // if side == TRADE_SIDE_SHORT (user receives premia) the fees are substracted from the premia
    let (total_fees) = get_fees(total_premia_before_fees);
    let (total_premia) = _add_premia_fees(side, total_premia_before_fees, total_fees);

    // 9) Make the trade
    // FIXME: consider dropping the option_token_address and finding it inside of the liquidity_pool.mint_option_token
    let (option_token_address) = ILiquidityPool.get_option_token_address(
        contract_address=pool_address,
        option_side=side,
        option_type=option_type,
        maturity=maturity,
        strike_price=strike_price
    );
    // FIXME: switch from separate premia and fees to using combined number her
    ILiquidityPool.burn_option_token(
        contract_address=pool_address,
        option_token_address=option_token_address,
        amount=option_size,
        option_side=side,
        option_type=option_type,
        maturity=maturity,
        strike=strike_price,
        premia=total_premia_before_fees,
        fees=total_fees,
        underlying_price=underlying_price,
    );

    return (premia=premia);
}


@external
func trade{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    option_type : OptionType,
    strike_price : Math64x61_,
    maturity : Int,
    side : OptionSide,
    option_size : Math64x61_,
    underlying_asset: felt,
    open_position: Bool, // True or False... determines if the user wants to open or close the position
) -> (premia : Math64x61_) {
    let (option_is_available) = get_available_options(
        underlying_asset,
        option_type,
        strike_price,
        maturity
    );
    with_attr error_message("Option is not available") {
        assert option_is_available = TRUE;
    }

    with_attr error_message("Given option_type is not available") {
        assert (option_type - OPTION_CALL) * (option_type - OPTION_PUT) = 0;
    }

    with_attr error_message("Given option_side is not available") {
        assert (option_side - TRADE_SIDE_LONG) * (option_side - TRADE_SIDE_SHORT) = 0;
    }

    with_attr error_message("open_position is not bool") {
        assert (open_position - TRUE) * (open_position - fALSE) = 0;
    }

    // Check that maturity hasn't passed
    let (currtime) = get_block_timestamp();
    with_attr error_message("Given maturity has already expired") {
        assert_le(currtime, maturity);
    }
    with_attr error_message("Trading of given maturity has been stopped before expiration") {
        assert_le(currtime, maturity - STOP_TRADING_BEFORE_MATURITY_SECONDS);
    }

    // Check that option_size>0 (same as size>=1... because 1 is a smallest unit)
    with_attr error_message("Option size is not positive") {
        assert_le(1, option_size);
    }

    // Check that account has enough amount of given token to pay for premia and/or locked capital.
    // If this is not the case, the transaction fails, because the tokens can't be transfered.

    // Check that there is enough available capital in the given pool.
    // If this is not the case, the transaction fails, because the tokens can't be transfered.

    if open_position == TRUE {

        let (premia) = do_trade(
            option_type,
            strike_price,
            maturity,
            side,
            option_size,
            underlying_asset
        );
        return (premia=premia);
    } else {
        let (premia) = close_position(
            option_type,
            strike_price,
            maturity,
            side,
            option_size,
            underlying_asset
        );
        return (premia=premia);
    }
}
