import asyncio
import json
import time

from starknet_py.contract import Contract
from starknet_py.net import AccountClient, KeyPair
from starknet_py.net.account.account import Account
from starknet_py.net.gateway_client import GatewayClient
from starknet_py.net.models.chains import StarknetChainId



CLASS_HASH=0x0489c4d9adf068ae5198f9bd180450fdf5aceb5e6989a958b8833cb45f1f2b6c # testnet1
contract_address = (
    0x042a7d485171a01b8c38b6b37e0092f0f096e9d3f945c50c77799171916f5a54  # testnet production contract
    # 0x05cade694670f80dca1195c77766b643dce01f511eca2b7250ef113b57b994ec  # testnet "testdev" contract - staging
)


testnet = "testnet"
MAX_FEE=int(1e16)
QUOTE_TOKEN_ADDRESS=159707947995249021625440365289670166666892266109381225273086299925265990694 # testnet 1
BASE_TOKEN_ADDRESS=2087021424722619777119509474943472645767659996348769578120564519014510906823 # testnets both
LPTOKENS = {
    0x042a7d485171a01b8c38b6b37e0092f0f096e9d3f945c50c77799171916f5a54: {
        0: 0x3b176f8e5b4c9227b660e49e97f2d9d1756f96e5878420ad4accd301dd0cc17, #call testnet
        1: 0x30fe5d12635ed696483a824eca301392b3f529e06133b42784750503a24972 # put testnet
    },
    0x05cade694670f80dca1195c77766b643dce01f511eca2b7250ef113b57b994ec: {
        0: 0x0149a0249403aa85859297ac2e3c96b7ca38f2b36d7a34212dcfbc92e8d66eb1, # call testdev
        1: 0x077868613647e04cfa11593f628598e93071d52ca05f1e89a70add4bb3470897 # put testdev
    }
}


INITIAL_VOLATILITY = 184467440737095516160  # 80*2**61
strike_1300 = 2997595911977802137600  # 1300 * 2**61
strike_1400 = 3228180212899171532800
strike_1500 = 3458764513820540928000
strike_1600 = 3689348814741910323200
strike_1700 = 3919933115663279718400
strike_1800 = 4150517416584649113600
# maturity = 1675987199
maturity = 1677196799
options_to_be_deployed = [
    # {'option_type': 0, 'strike_price': strike_1500, 'maturity': maturity, 'side': 0},
    # {'option_type': 0, 'strike_price': strike_1500, 'maturity': maturity, 'side': 1},
    # {'option_type': 0, 'strike_price': strike_1600, 'maturity': maturity, 'side': 0},
    # {'option_type': 0, 'strike_price': strike_1600, 'maturity': maturity, 'side': 1},
    # {'option_type': 0, 'strike_price': strike_1700, 'maturity': maturity, 'side': 0},
    # {'option_type': 0, 'strike_price': strike_1700, 'maturity': maturity, 'side': 1},
    # {'option_type': 0, 'strike_price': strike_1800, 'maturity': maturity, 'side': 0},
    # {'option_type': 0, 'strike_price': strike_1800, 'maturity': maturity, 'side': 1},

    # {'option_type': 1, 'strike_price': strike_1600, 'maturity': maturity, 'side': 0},
    # {'option_type': 1, 'strike_price': strike_1600, 'maturity': maturity, 'side': 1},
    # {'option_type': 1, 'strike_price': strike_1500, 'maturity': maturity, 'side': 0},
    # {'option_type': 1, 'strike_price': strike_1500, 'maturity': maturity, 'side': 1},
    {'option_type': 1, 'strike_price': strike_1400, 'maturity': maturity, 'side': 0},
    {'option_type': 1, 'strike_price': strike_1400, 'maturity': maturity, 'side': 1},
    {'option_type': 1, 'strike_price': strike_1300, 'maturity': maturity, 'side': 0},
    {'option_type': 1, 'strike_price': strike_1300, 'maturity': maturity, 'side': 1},
]

async def main():

    client = GatewayClient(net=testnet)
    account = Account(
        client=client,
        address=...,
        key_pair=KeyPair(
            private_key=...,
            public_key=...
        ),
        chain=StarknetChainId.TESTNET,
    )
    print('Account created')

    with open("build/amm_abi.json") as f:
        abi_amm = json.load(f)

    with open("build/option_token_abi.json") as f:
        abi_option_token = json.load(f)

    contract = Contract(
        address=contract_address,
        abi=abi_amm,
        provider=account,
    )
    print('Contract created')

    calls = []

    print('Starting to process options')
    for option in options_to_be_deployed:
        print('Option is being processed')
        constructor_args = {
            'name': 123456789,
            'symbol': 1234,
            'decimals': 18,
            'initial_supply': {'low': 0, 'high': 0},
            'recipient': contract_address,
            'owner': contract_address,
            'quote_token_address': QUOTE_TOKEN_ADDRESS,
            'base_token_address': BASE_TOKEN_ADDRESS,
            'option_type': option['option_type'],
            'strike_price': option['strike_price'],
            'maturity': option['maturity'],
            'side': option['side'],
        }

        deploy_result = await Contract.deploy_contract(
            account=account,
            class_hash=CLASS_HASH,
            abi=abi_option_token,
            constructor_args=constructor_args,
            max_fee=MAX_FEE,
        )
        await deploy_result.wait_for_acceptance()

        # To interact with just deployed contract get its instance from the deploy_result
        option_token_contract = deploy_result.deployed_contract
        print('Option token deployed: ', hex(option_token_contract.address))

        calls.append(
            contract.functions["add_option"].prepare(
                option_side=option['side'],
                maturity=option['maturity'],
                strike_price=option['strike_price'],
                quote_token_address=QUOTE_TOKEN_ADDRESS,
                base_token_address=BASE_TOKEN_ADDRESS,
                option_type=option['option_type'],
                lptoken_address=LPTOKENS[contract_address][option['option_type']],
                option_token_address_=option_token_contract.address,
                initial_volatility=INITIAL_VOLATILITY,
            )
        )
        print('Call prepared: ', option)
        print('---------------------------------------------------')



    # Executes only one transaction with prepared calls
    print('Starting to execute the multicall')

    transaction_response = await account.execute(calls=calls, max_fee=int(1e16))
    await account.client.wait_for_tx(transaction_response.transaction_hash)

    print(transaction_response)

    print('Multicall executed')

asyncio.run(main())
print('Everything is done')
