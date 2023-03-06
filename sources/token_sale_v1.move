module suipad::token_sale_v1 {
    use sui::tx_context::{Self, TxContext};
    use std::vector;
    use sui::object::{Self, UID, ID};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::table::{Self, Table};

    
    const ERR_ONLY_ADMIN_CAN_CREATE_PRESALE: u64 = 1;
    const ERR_SETTING_UP_SPENDING_LIMIT: u64 = 2;
    const ERR_SETTING_UP_CAP_LIMIT: u64 = 3;
    const ERR_SETTING_UP_SALE_TIME: u64 = 4;
    const ERR_SETTING_UP_TOKEN_DISTRIBUTION_TIME: u64 = 5;
    const ERR_CALL_BUY_AGAIN_FUNCTION: u64 = 6;
    const ERR_SALE_IS_NOT_IN_UPCOMING_STATE: u64 = 7;
    const ERR_ONLY_ADMIN_ACCESS: u64 = 8;
    const ERR_PRESALE_IS_NOT_ACTIVE: u64 = 9;
    const ERR_SPENDING_LIMIT_NOT_SATISFIED: u64 = 10;
    const ERR_TOKEN_DISTRIBUTION_NOT_STARTED: u64 = 11;
    const ERR_PRESALE_IS_NOT_COMPLETED: u64 = 12;
    const ERR_USER_CLAIMABLE_TOKEN_NOT_FOUND: u64 = 13;
    const ERR_IS_NOT_COIN: u64 = 14;
    const ERR_INSUFFICIENT_COIN_INPUT: u64 = 15;
    const ERR_PRESALE_EXISTS: u64 = 16;
    const ERR_NOT_WHITELISTED: u64 = 17;
    const ERR_SALE_HARDCAP_REACHED: u64 = 18;
    

    //ownership of the objects 
    struct AdminCap has key { id: UID }

    struct PresaleInfo<phantom CoinType> has key {
        id: UID,
        min_spend_per_user: u64,
        max_spend_per_user: u64,
        amount_to_be_raised: u64,
        amount_raised: u64,
        token_to_be_sold: u64,
        softcap: u64,
        sale_start_ts: u64,
        sale_end_ts: u64,
        token_distribution_ts: u64,
        sale_status: u64,                       //1=Upcoming, 2=Ongoing, 3=Closed, 4=Aborted/Forced Closed
        is_whitelist: bool,
        whitelist: vector<address>,
        participated: u64,
        coin_reserve: Balance<CoinType>,
        sui_reserve: Balance<SUI>,
        user_map: Table<address, ID>
    }

    struct WithdrawbleToken has key, store {
        id: UID,
        sale_id: ID,
        base_token_amount: u64,
        withdrawable_token_amount: u64
    }


    fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, tx_context::sender(ctx));
    }

    public entry fun create_presale<CoinType>(
            _: &AdminCap,
            min_spend_per_user: u64,
            max_spend_per_user: u64,
            amount_to_be_raised: u64,
            token_to_be_sold: u64,
            softcap: u64,
            sale_start_ts: u64,
            sale_end_ts: u64,
            token_distribution_ts: u64,
            is_whitelist: bool,
            coin_in: Coin<CoinType>,
            ctx: &mut TxContext
        ) {
        assert!(min_spend_per_user < max_spend_per_user, ERR_SETTING_UP_SPENDING_LIMIT);
        assert!(softcap < amount_to_be_raised, ERR_SETTING_UP_CAP_LIMIT);
        //timestamp function
        assert!(sale_end_ts < token_distribution_ts, ERR_SETTING_UP_TOKEN_DISTRIBUTION_TIME);
        assert!(coin::value(&coin_in) == token_to_be_sold, ERR_INSUFFICIENT_COIN_INPUT);
        transfer::share_object(PresaleInfo {
            id: object::new(ctx),
            min_spend_per_user,
            max_spend_per_user,
            amount_to_be_raised,
            amount_raised: 0,
            token_to_be_sold,
            softcap,
            sale_start_ts,
            sale_end_ts,
            token_distribution_ts,
            sale_status: 1,
            is_whitelist,
            whitelist: vector::empty<address>(),
            participated: 0,
            coin_reserve: coin::into_balance(coin_in),
            sui_reserve: balance::zero<SUI>(),
            user_map: table::new(ctx)
        });

    }

    public entry fun user_deposit<CoinType>(presale: &mut PresaleInfo<CoinType>, sui_input: Coin<SUI>, ctx: &mut TxContext) {
        assert!(presale.sale_status == 2, ERR_PRESALE_IS_NOT_ACTIVE);
        
        // assert!(timestamp::now_seconds() > presale.sale_start_ts , ERR_PRESALE_IS_NOT_ACTIVE);
        // assert!(timestamp::now_seconds() < presale.sale_end_ts, ERR_PRESALE_IS_NOT_ACTIVE);
        let s_coins = coin::value(&sui_input);
        let user_addr = tx_context::sender(ctx);
        assert!(!table::contains(&presale.user_map, user_addr), ERR_CALL_BUY_AGAIN_FUNCTION);
        assert!((presale.amount_to_be_raised - presale.amount_raised) >= s_coins, ERR_SALE_HARDCAP_REACHED);
        //check whitelist for the user
        if (presale.is_whitelist ) {
            // find the user in the whitelist to get an entry to the sale
            assert!(vector::contains<address>(&presale.whitelist, &user_addr), ERR_NOT_WHITELISTED);
        };
        
        assert!(s_coins <= presale.max_spend_per_user, ERR_SPENDING_LIMIT_NOT_SATISFIED);
        assert!(s_coins >= presale.min_spend_per_user , ERR_SPENDING_LIMIT_NOT_SATISFIED);
        let withdrawable = WithdrawbleToken {
            id: object::new(ctx),
            sale_id: object::id(presale),
            base_token_amount: s_coins,
            withdrawable_token_amount: (s_coins * presale.token_to_be_sold)/presale.amount_to_be_raised,
        };
        table::add(&mut presale.user_map, user_addr, object::id(&withdrawable));
        transfer::transfer(withdrawable, user_addr);
        presale.participated = presale.participated + 1;

        presale.amount_raised = presale.amount_raised + s_coins;
        balance::join(&mut presale.sui_reserve,  coin::into_balance(sui_input));
    }

    public entry fun user_deposit_update<CoinType>(presale: &mut PresaleInfo<CoinType>, withdrawable: &mut WithdrawbleToken, sui_input: Coin<SUI>, ctx: &mut TxContext) {
        assert!(presale.sale_status == 2, ERR_PRESALE_IS_NOT_ACTIVE);
        
        // assert!(timestamp::now_seconds() > presale.sale_start_ts , ERR_PRESALE_IS_NOT_ACTIVE);
        // assert!(timestamp::now_seconds() < presale.sale_end_ts, ERR_PRESALE_IS_NOT_ACTIVE);
        let s_coins = coin::value(&sui_input);
        let user_addr = tx_context::sender(ctx);
        assert!(table::contains(&presale.user_map, user_addr), ERR_CALL_BUY_AGAIN_FUNCTION);
        assert!((presale.amount_to_be_raised - presale.amount_raised) >= s_coins, ERR_SALE_HARDCAP_REACHED);
        //check whitelist for the user
        if (presale.is_whitelist ) {
            // find the user in the whitelist to get an entry to the sale
            assert!(vector::contains<address>(&presale.whitelist, &user_addr), ERR_NOT_WHITELISTED);
        };
        assert!(s_coins + withdrawable.base_token_amount <= presale.max_spend_per_user, ERR_SPENDING_LIMIT_NOT_SATISFIED);
        assert!(s_coins >= presale.min_spend_per_user , ERR_SPENDING_LIMIT_NOT_SATISFIED);
        withdrawable.base_token_amount = withdrawable.base_token_amount + s_coins;
        withdrawable.withdrawable_token_amount = withdrawable.withdrawable_token_amount + (s_coins * presale.token_to_be_sold)/presale.amount_to_be_raised;

        presale.amount_raised = presale.amount_raised + s_coins;
        balance::join(&mut presale.sui_reserve,  coin::into_balance(sui_input));
    }


    public entry fun claim_token<CoinType>(presale: &mut PresaleInfo<CoinType>, user_claim: WithdrawbleToken, ctx: &mut TxContext) {
        assert!(presale.sale_status == 3 , ERR_PRESALE_IS_NOT_COMPLETED);
        let user_addr = tx_context::sender(ctx);
        assert!(table::contains(&presale.user_map, user_addr), ERR_USER_CLAIMABLE_TOKEN_NOT_FOUND);
        let token = coin::take(&mut presale.coin_reserve, user_claim.withdrawable_token_amount, ctx);
        let WithdrawbleToken {id, sale_id: _, base_token_amount: _, withdrawable_token_amount: _ } = user_claim;
        //remove from table entry, consume the withdrawable object
        table::remove(&mut presale.user_map, user_addr);
        object::delete(id);
        transfer::transfer(token, tx_context::sender(ctx));
    }

    public entry fun admin_withdraw_from_presale<CoinType>(_: &AdminCap, presale: &mut PresaleInfo<CoinType>, ctx: &mut TxContext) {
        assert!(presale.sale_status == 3 || presale.sale_status == 4 , ERR_PRESALE_IS_NOT_COMPLETED);
        let remaining_coin = balance::value(&presale.coin_reserve);
        let coins = coin::take(&mut presale.coin_reserve, remaining_coin, ctx);
        transfer::transfer(coins, tx_context::sender(ctx));

        let remaining_sui = balance::value(&presale.sui_reserve);
        let sui_out = coin::take(&mut presale.sui_reserve, remaining_sui, ctx);
        transfer::transfer(sui_out, tx_context::sender(ctx));
    }

    public entry fun change_sale_status<CoinType>(_: &AdminCap, presale: &mut PresaleInfo<CoinType>, status: u64, _ctx: &mut TxContext) {
        presale.sale_status = status;
    }

    public entry fun enable_disable_whitelist<CoinType>(_: &AdminCap, presale: &mut PresaleInfo<CoinType>, status: bool, _ctx: &mut TxContext) {
        presale.is_whitelist = status;
    }

    public entry fun update_max_spend_limit<CoinType>(_: &AdminCap, presale: &mut PresaleInfo<CoinType>, limit: u64, _ctx: &mut TxContext) {
        presale.max_spend_per_user = limit;
    }
    
    public entry fun add_to_whitelist<CoinType>(_: &AdminCap, presale: &mut PresaleInfo<CoinType>, list: vector<address>, _ctx: &mut TxContext) {
        assert!(presale.sale_status == 1, ERR_SALE_IS_NOT_IN_UPCOMING_STATE);
        vector::append(&mut presale.whitelist, list);
    }

    //getters
    // public fun profits(grocery: &Grocery): u64 {
    //     balance::value(&grocery.profits)
    // }
    //returns min_spend, max_spend, amount_to_be_raised, amount raised so far, token_to_be_sold, softcap
    public fun get_presale_token_details<CoinType>(presale: &PresaleInfo<CoinType>): (u64, u64, u64, u64, u64, u64){
        (presale.min_spend_per_user, presale.max_spend_per_user, presale.amount_to_be_raised, presale.amount_raised, presale.token_to_be_sold, presale.softcap)
    }

    //returns sale_start ts, sale end ts, token distribution time, sale status
    public fun get_presale_time_details<CoinType>(presale: &PresaleInfo<CoinType>): (u64, u64, u64, u64) {
        (presale.sale_start_ts, presale.sale_end_ts, presale.token_distribution_ts, presale.sale_status)
    }

    // returns whitelist and participant numbers
    public fun get_presale_whitelist_numbers<CoinType>(presale: &PresaleInfo<CoinType>): (u64, u64) {
        (vector::length(&presale.whitelist), presale.participated)
    }

    //added new *******>>>>
    //returns true/false for user whitelisted
    public fun is_user_whitelisted<CoinType>(presale: &PresaleInfo<CoinType>, user_addr: address): bool {
        vector::contains<address>(&presale.whitelist, &user_addr)
    }

    //returns amount of tokens reserved in the treasury for the presale
    public fun get_presale_reserve<CoinType>(presale: &PresaleInfo<CoinType>): (u64, u64) {
        (balance::value(&presale.coin_reserve), balance::value(&presale.sui_reserve))
    }
    

    public fun get_user_info_by_address(user_claim: &WithdrawbleToken): (u64, u64) {
        (user_claim.base_token_amount, user_claim.withdrawable_token_amount)
    } 
    //for init testing
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}

#[test_only]
module suipad::token_sale_test {
    use sui::sui::SUI;
    use std::vector;
    use std::debug;
    use sui::coin::{mint_for_testing as mint};
    use sui::test_scenario::{Self, next_tx, ctx}
    ;
    use suipad::token_sale_v1::{Self, AdminCap, PresaleInfo, WithdrawbleToken};

    //test token
    struct BEEP {}

    #[test]
    fun test_create_presale() {
        let owner = @0x1;
        let user_2 = @0x2;
        let user_3 = @0x3;
        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        test_scenario::next_tx(scenario, owner);
        next_tx(scenario, owner);
        {
            token_sale_v1::init_for_testing(ctx(scenario));
        };
        next_tx(scenario, owner);
        {
            let capability = test_scenario::take_from_sender<AdminCap>(scenario);
            token_sale_v1::create_presale<BEEP>(
                &capability,
                1000000,
                3000000,
                10000000,
                100000000,
                5000000,
                1668322591,
                1668325691,
                1668329791,
                true,
                mint<BEEP>(100000000, ctx(scenario)),
                ctx(scenario)
            );
            test_scenario::return_to_sender(scenario, capability);
        };
        next_tx(scenario, owner);
        {

            //checked all the velue
            let presale_val = test_scenario::take_shared<PresaleInfo<BEEP>>(scenario);
            let (min_spend, _, _, _, _, _) = token_sale_v1::get_presale_token_details<BEEP>(&presale_val);
            assert!(min_spend == 1000000, 1);
            let (coin_r, sui_r) = token_sale_v1::get_presale_reserve<BEEP>(&presale_val);
            assert!(coin_r == 100000000, 3);
            assert!(sui_r == 0, 2);
            let ( _, _, _, status) = token_sale_v1::get_presale_time_details<BEEP>(&presale_val);
            assert!(status == 1, 4);

            //adding user to the whitelist
            let v = vector::empty<address>();
            vector::push_back(&mut v, user_2);
            let capability = test_scenario::take_from_sender<AdminCap>(scenario);
            token_sale_v1::add_to_whitelist(&capability, &mut presale_val, v, ctx(scenario));
            token_sale_v1::change_sale_status(&capability, &mut presale_val, 2, ctx(scenario));
            test_scenario::return_to_sender(scenario, capability);
            test_scenario::return_shared(presale_val);
        };
        next_tx(scenario, user_2);
        {
            let presale_val = test_scenario::take_shared<PresaleInfo<BEEP>>(scenario);
            let ( _, _, _, status) = token_sale_v1::get_presale_time_details<BEEP>(&presale_val);
            assert!(status == 2, 4);
            let is_white = token_sale_v1::is_user_whitelisted<BEEP>(&presale_val, user_2);
            assert!(is_white, 5);
            let is_white_3 = token_sale_v1::is_user_whitelisted<BEEP>(&presale_val, user_3);
            assert!(!is_white_3, 6);
            
            token_sale_v1::user_deposit(
                &mut presale_val,
                mint<SUI>(1000000, ctx(scenario)),
                ctx(scenario)
            );

            test_scenario::return_shared(presale_val);
        };

        next_tx(scenario, owner);
        {
            let capability = test_scenario::take_from_sender<AdminCap>(scenario);
            let presale_val = test_scenario::take_shared<PresaleInfo<BEEP>>(scenario);
            let (coin_r, sui_r) = token_sale_v1::get_presale_reserve<BEEP>(&presale_val);
            assert!(coin_r == 100000000, 7);
            assert!(sui_r == 1000000, 8);
            token_sale_v1::change_sale_status(&capability, &mut presale_val, 3, ctx(scenario));
            test_scenario::return_to_sender(scenario, capability);
            test_scenario::return_shared(presale_val);
        };

        next_tx(scenario, user_2);
        {
            let presale_val = test_scenario::take_shared<PresaleInfo<BEEP>>(scenario);
            let user_claim = test_scenario::take_from_sender<WithdrawbleToken>(scenario);
            token_sale_v1::claim_token<BEEP>(&mut presale_val, user_claim, ctx(scenario));
            // test_scenario::return_to_sender(scenario, user_claim);
            test_scenario::return_shared(presale_val);
        };

        next_tx(scenario, user_2);
        {
            let presale_val = test_scenario::take_shared<PresaleInfo<BEEP>>(scenario);
            let (coin_r, sui_r) = token_sale_v1::get_presale_reserve<BEEP>(&presale_val);
            debug::print<u64>(&coin_r);
            debug::print<u64>(&sui_r);
            // let user_balance = test_scenario::take

            test_scenario::return_shared(presale_val);
        };
        

        test_scenario::end(scenario_val);
    }
}