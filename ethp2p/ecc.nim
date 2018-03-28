#
#                 Ethereum P2P
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements `libsecp256k1` ECC/ECDH functions

import secp256k1, hexdump, nimcrypto/sysrand, nimcrypto/utils

const
  KeyLength* = 32
  PublicKeyLength* = 64
  SignatureLength* = 65


type
  EccContext* = ref object of RootRef
    context*: ptr secp256k1_context
    error*: string

  EccStatus* = enum
    Success,  ## Operation was successful
    Error     ## Operation failed

  PublicKey* = secp256k1_pubkey
    ## Representation of public key

  PrivateKey* = array[KeyLength, byte]
    ## Representation of secret key

  SharedSecret* = array[KeyLength, byte]
    ## Representation of ECDH shared secret

  Nonce* = array[KeyLength, byte]
    ## Representation of nonce

  RawPublickey* = object
    ## Representation of serialized public key
    header*: byte
    data*: array[KeyLength * 2, byte]

  KeyPair* = object
    ## Representation of private/public keys pair
    seckey*: PrivateKey
    pubkey*: PublicKey

  Signature* = secp256k1_ecdsa_recoverable_signature
    ## Representation of signature

  RawSignature* = object
    ## Representation of serialized signature
    data*: array[KeyLength * 2 + 1, byte]

  Secp256k1Exception* = object of Exception
    ## Exceptions generated by `libsecp256k1`
  EccException* = object of Exception
    ## Exception generated by this module

var eccContext* {.threadvar.}: EccContext
  ## Thread local variable which holds current context

proc illegalCallback(message: cstring; data: pointer) {.cdecl.} =
  let ctx = cast[EccContext](data)
  ctx.error = $message

proc errorCallback(message: cstring, data: pointer) {.cdecl.} =
  let ctx = cast[EccContext](data)
  ctx.error = $message

proc newEccContext*(): EccContext =
  ## Create new `EccContext`.
  result = new EccContext
  let flags = cuint(SECP256K1_CONTEXT_VERIFY or SECP256K1_CONTEXT_SIGN)
  result.context = secp256k1_context_create(flags)
  secp256k1_context_set_illegal_callback(result.context, illegalCallback,
                                         cast[pointer](result))
  secp256k1_context_set_error_callback(result.context, errorCallback,
                                       cast[pointer](result))
  result.error = ""

proc getSecpContext*(): ptr secp256k1_context =
  ## Get current `secp256k1_context`
  if isNil(eccContext):
    eccContext = newEccContext()
  result = eccContext.context

proc getEccContext*(): EccContext =
  ## Get current `EccContext`
  if isNil(eccContext):
    eccContext = newEccContext()
  result = eccContext

template raiseSecp256k1Error*() =
  ## Raises `libsecp256k1` error as exception
  let mctx = getEccContext()
  if len(mctx.error) > 0:
    var msg = mctx.error
    mctx.error.setLen(0)
    raise newException(Secp256k1Exception, msg)

proc eccErrorMsg*(): string =
  let mctx = getEccContext()
  result = mctx.error

proc setErrorMsg*(m: string) =
  let mctx = getEccContext()
  mctx.error = m

proc getRaw*(pubkey: PublicKey): RawPublickey =
  ## Converts public key `pubkey` to serialized form of `secp256k1_pubkey`.
  var length = csize(sizeof(RawPublickey))
  let ctx = getSecpContext()
  if secp256k1_ec_pubkey_serialize(ctx, cast[ptr cuchar](addr result),
                                   addr length, unsafeAddr pubkey,
                                   SECP256K1_EC_UNCOMPRESSED) != 1:
    raiseSecp256k1Error()
  if length != 65:
    raise newException(EccException, "Invalid public key length!")
  if result.header != 0x04'u8:
    raise newException(EccException, "Invalid public key header!")

proc getRaw*(s: Signature): RawSignature =
  ## Converts signature `s` to serialized form.
  let ctx = getSecpContext()
  var recid = cint(0)
  if secp256k1_ecdsa_recoverable_signature_serialize_compact(
    ctx, cast[ptr cuchar](unsafeAddr result), addr recid, unsafeAddr s) != 1:
    raiseSecp256k1Error()
  result.data[64] = uint8(recid)

proc signMessage*(seckey: PrivateKey, data: ptr byte, length: int,
                  sig: var Signature): EccStatus =
  ## Sign message pointed by `data` with size `length` and save signature to
  ## `sig`.
  let ctx = getSecpContext()
  if secp256k1_ecdsa_sign_recoverable(ctx, addr sig,
                                      cast[ptr cuchar](data),
                                      cast[ptr cuchar](unsafeAddr seckey[0]),
                                      nil, nil) != 1:
    return(Error)
  return(Success)

proc signMessage*[T](seckey: PrivateKey, data: openarray[T],
                     sig: var Signature, ostart: int = 0,
                     ofinish: int = -1): EccStatus =
  ## Sign message ``data``[`soffset`..`eoffset`] and store result into `sig`.
  let so = ostart
  let eo = if ofinish == -1: (len(data) - 1) else: ofinish
  let length = (eo - so + 1) * sizeof(T)
  # We don't need to check `so` because compiler will do it for `data[so]`.
  if eo >= len(data):
    setErrorMsg("Index is out of bounds!")
    return(Error)
  if len(data) < KeyLength or length < KeyLength:
    setErrorMsg("There no reason to sign this message!")
    return(Error)
  result = signMessage(seckey, cast[ptr byte](unsafeAddr data[so]),
                       length, sig)

proc recoverSignatureKey*(data: ptr byte, length: int, message: ptr byte,
                          pubkey: var PublicKey): EccStatus =
  ## Check signature and return public key from `data` with size `length` and
  ## `message`.
  let ctx = getSecpContext()
  var s: secp256k1_ecdsa_recoverable_signature
  if length >= 65:
    var recid = cint(cast[ptr UncheckedArray[byte]](data)[KeyLength * 2])
    if secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, addr s,
                                                         cast[ptr cuchar](data),
                                                           recid) != 1:
      return(Error)

    if secp256k1_ecdsa_recover(ctx, addr pubkey, addr s,
                               cast[ptr cuchar](message)) != 1:
      setErrorMsg("Message signature verification failed!")
      return(Error)
    return(Success)
  else:
    setErrorMsg("Incorrect signature size")
    return(Error)

proc recoverSignatureKey*[A, B](data: openarray[A],
                                message: openarray[B],
                                pubkey: var PublicKey,
                                ostart: int = 0,
                                ofinish: int = -1): EccStatus =
  ## Check signature in ``data``[`soffset`..`eoffset`] and recover public key
  ## from signature to ``pubkey`` using message `message`.
  if len(message) == 0:
    setErrorMsg("Message could not be empty!")
    return(Error)
  let so = ostart
  let eo = if ofinish == -1: (len(data) - 1) else: ofinish
  let length = (eo - so + 1) * sizeof(A)
  # We don't need to check `so` because compiler will do it for `data[so]`.
  if eo > len(data):
    setErrorMsg("Index is out of bounds!")
    return(Error)
  if length < sizeof(RawSignature) or len(data) < sizeof(RawSignature):
    setErrorMsg("Invalid signature size!")
    return(Error)
  result = recoverSignatureKey(cast[ptr byte](unsafeAddr data[so]), length,
                               cast[ptr byte](unsafeAddr message[0]), pubkey)

proc ecdhAgree*(seckey: PrivateKey, pubkey: PublicKey,
                secret: var SharedSecret): EccStatus =
  ## Calculate ECDH shared secret
  var res: array[KeyLength + 1, byte]
  let ctx = getSecpContext()
  if secp256k1_ecdh_raw(ctx, cast[ptr cuchar](addr res),
                        unsafeAddr pubkey,
                        cast[ptr cuchar](unsafeAddr seckey)) != 1:
    return(Error)
  copyMem(addr secret[0], addr res[1], KeyLength)
  return(Success)

proc getPublicKey*(seckey: PrivateKey): PublicKey =
  ## Return public key for private key `seckey`.
  let ctx = getSecpContext()
  if secp256k1_ec_pubkey_create(ctx, addr result,
                                cast[ptr cuchar](unsafeAddr seckey[0])) != 1:
    raiseSecp256k1Error()


proc recoverPublicKey*(data: ptr byte, length: int,
                       pubkey: var PublicKey): EccStatus =
  ## Unserialize public key from `data` pointer and size `length` and'
  ## set `pubkey`.
  let ctx = getSecpContext()
  if length < sizeof(PublicKey):
    setErrorMsg("Invalid public key!")
    return(Error)
  var rawkey: RawPublickey
  rawkey.header = 0x04 # mark key with COMPRESSED flag
  copyMem(addr rawkey.data[0], data, len(rawkey.data))
  if secp256k1_ec_pubkey_parse(ctx, addr pubkey,
                               cast[ptr cuchar](addr rawkey),
                               sizeof(RawPublickey)) != 1:
    return(Error)
  return(Success)

proc recoverPublicKey*[T](data: openarray[T], pubkey: var PublicKey,
                          ostart: int = 0, ofinish: int = -1, ): EccStatus =
  ## Unserialize public key from openarray[T] `data`, from position `ostart` to
  ## position `ofinish` and save it to `pubkey`.
  let so = ostart
  let eo = if ofinish == -1: (len(data) - 1) else: ofinish
  let length = (eo - so + 1) * sizeof(T)
  # We don't need to check `so` because compiler will do it for `data[so]`.
  if eo > len(data):
    setErrorMsg("Index is out of bounds!")
    return(Error)
  if length < sizeof(PublicKey) or len(data) < sizeof(PublicKey):
    setErrorMsg("Invalid public key size!")
    return(Error)
  result = recoverPublicKey(cast[ptr byte](unsafeAddr data[so]), length,
                            pubkey)

proc newPrivateKey*(): PrivateKey =
  ## Generates new secret key.
  let ctx = getSecpContext()
  while true:
    if randomBytes(addr result[0], KeyLength) == KeyLength:
      if secp256k1_ec_seckey_verify(ctx, cast[ptr cuchar](addr result[0])) == 1:
        break

proc newKeyPair*(): KeyPair =
  ## Generates new private and public key.
  result.seckey = newPrivateKey()
  result.pubkey = result.seckey.getPublicKey()

proc getPrivateKey*(hexstr: string): PrivateKey =
  ## Set secret key from hexadecimal string representation.
  let ctx = getSecpContext()
  var o = fromHex(stripSpaces(hexstr))
  if len(o) < KeyLength:
    raise newException(EccException, "Invalid private key!")
  copyMem(addr result[0], unsafeAddr o[0], KeyLength)
  if secp256k1_ec_seckey_verify(ctx, cast[ptr cuchar](addr result[0])) != 1:
    raise newException(EccException, "Invalid private key!")

proc getPublicKey*(hexstr: string): PublicKey =
  ## Set public key from hexadecimal string representation.
  var o = fromHex(stripSpaces(hexstr))
  if recoverPublicKey(o, result) != Success:
    raise newException(EccException, "Invalid public key!")

proc dump*(s: openarray[byte], c: string = ""): string =
  ## Return hexadecimal dump of array `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  if len(s) > 0:
    result &= dumpHex(unsafeAddr s[0], len(s))
  else:
    result &= "[]"

proc dump*(s: PublicKey, c: string = ""): string =
  ## Return hexadecimal dump of public key `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s.data[0], sizeof(secp256k1_pubkey))

proc dump*(s: RawSignature, c: string = ""): string =
  ## Return hexadecimal dump of serialized signature `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s.data[0], sizeof(RawSignature))

proc dump*(s: RawPublickey, c: string = ""): string =
  ## Return hexadecimal dump of serialized public key `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s, sizeof(RawSignature))

proc dump*(s: secp256k1_ecdsa_recoverable_signature, c: string = ""): string =
  ## Return hexadecimal dump of signature `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s.data[0],
                    sizeof(secp256k1_ecdsa_recoverable_signature))

proc dump*(p: pointer, s: int, c: string = ""): string =
  ## Return hexadecimal dump of memory blob `p` and size `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(p, s)
