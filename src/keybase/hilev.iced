
#
# A high-level interface to keybase-style signatures and encryptions,
# via the Keybase packet format, and the NaCl libraries.
#
#=================================================================================

{KeyManagerInterface} = require '../kmi'
{make_esc} = require 'iced-error'
encode = require './encode'
{buffer_xor,asyncify,akatch} = require '../util'
konst = require '../const'
{alloc} = require './packet/alloc'
{Signature} = require './packet/signature'
{Encryption} = require './packet/encryption'
{EdDSA} = require '../nacl/eddsa'
{DH} = require '../nacl/dh'
K = konst.kb
C = konst.openpgp

#======================================================================

class KeyManager extends KeyManagerInterface

  constructor : ({@key, @server_half}) ->

  @generate : ({algo, seed, split, server_half, klass}, cb) ->
    algo or= EdDSA
    klass or= KeyManager
    await algo.generate {split, seed, server_half}, defer err, key, server_half
    cb err, new klass { key, server_half }

  #----------------------------------

  get_mask : () -> (C.key_flags.sign_data | C.key_flags.certify_keys | C.key_flags.auth)

  #----------------------------------

  fetch : (key_ids, flags, cb) ->
    s = @key.ekid().toString('hex')
    key = null
    mask = @get_mask()
    if (s in key_ids) and (flags & mask) is flags
      key = @key
    else
      err = new Error "Key not found"
    cb err, key

  #----------------------------------

  get_keypair : () -> @key
  get_primary_keypair : () -> @key

  #----------------------------------

  eq : (km2) -> @key.eq(km2.key)

  #----------------------------------

  @import_public : ({hex, raw}, cb) ->
    err = ret = null
    if hex?
      raw = new Buffer hex, 'hex'
    [err, key] = EdDSA.parse_kb raw
    unless err?
      ret = new KeyManager { key }
    cb err, ret

  #----------------------------------

  check_public_eq : (km2) -> @eq(km2)

  #----------------------------------

  export_public : ({asp, regen}, cb) ->
    ret = @key.ekid().toString('hex')
    cb null, ret

  #----------------------------------

  export_server_half : () -> @server_half?.toString 'hex'

  #----------------------------------

  get_ekid : () -> return @get_keypair().ekid()

  #----------------------------------

  make_sig_eng : () -> new SignatureEngine { km : @ }

#=================================================================================

class EncKeyManager extends KeyManager

  #----------------------------------

  @generate : (params, cb) ->
    params.algo = DH
    params.klass = EncKeyManager
    KeyManager.generate params, cb

  #----------------------------------

  make_sig_eng : () -> null

  #----------------------------------

  get_mask : () -> (C.key_flags.encrypt_comm | C.key_flags.encrypt_storage )

  #----------------------------------

  @import_public : ({hex, raw}, cb) ->
    err = ret = null
    if hex?
      raw = new Buffer hex, 'hex'
    [err, key] = DH.parse_kb raw
    unless err?
      ret = new KeyManager { key }
    cb err, ret

#=================================================================================

exports.unbox = unbox = ({armored,rawobj,encrypt_for}, cb) ->
  esc = make_esc cb, "unbox"

  if not armored? and not rawobj?
    await athrow (new Error "need either 'armored' or 'rawobj'"), esc defer()

  if armored?
    buf = new Buffer armored, 'base64'
    await akatch ( () -> encode.unseal buf), esc defer rawobj

  await asyncify alloc(rawobj), esc defer packet
  await packet.unbox {encrypt_for}, esc defer res

  if res.keypair?
    res.km = new KeyManager { key : res.keypair }
  if res.sender_keypair?
    res.sender_km = new KeyManager { key : res.sender_keypair }
  if res.receiver_keypair?
    res.receiver_km = new KeyManager { key : res.receiver_keypair }

  cb null, res

#=================================================================================

box = ({msg, sign_with, encrypt_for, anonymous}, cb) ->
  esc = make_esc cb, "box"
  if encrypt_for?
    await Encryption.box { sign_with, encrypt_for, plaintext : msg, anonymous }, esc defer packet
  else
    await Signature.box { km : sign_with, payload : msg }, esc defer packet
  packed = packet.frame_packet()
  sealed = encode.seal { obj : packed, dohash : false }
  armored = sealed.toString('base64')
  cb null, armored

#=================================================================================

class SignatureEngine

  #-----

  constructor : ({@km}) ->
  get_km      : -> @km

  #-----

  box : (msg, cb) ->
    esc = make_esc cb, "SignatureEngine::box"
    await box { msg, sign_with : @km }, esc defer armored
    out = { type : "kb", armored, kb : armored }
    cb null, out

  #-----

  unbox : (msg, cb) ->
    esc = make_esc cb, "SignatureEngine::unbox"
    err = payload = null
    await unbox { armored : msg }, esc defer res
    if not res.km.eq @km
      a = res.km.get_ekid().toString('hex')
      b = @km.get_ekid().toString('hex')
      err = new Error "Got wrong signing key: #{a} != #{b}"
    else
      payload = res.payload
    cb null, payload

#=================================================================

module.exports = { box, unbox, KeyManager, EncKeyManager }
