
;; title: stream
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; error codes
(define-constant ERR_UNAUTHORIZED (err u0))
(define-constant ERR_INVALID_SIGNATURE (err u1))
(define-constant ERR_STREAM_STILL_ACTIVE (err u2))
(define-constant ERR_INVALID_STREAM_ID (err u3))

;; data vars
(define-data-var latest-stream-id uint u0)
;;

;; data maps
(define-map streams 
    uint ;; this is the id of stream which is the key for the following data
    { 
        sender: principal, ;; Creator of the stream who is paying the recipient
        recipient: principal, ;; Payee of the stream getting paid by sender
        balance: uint, ;; Current STX tokens that are part of the stream's balance
        withdrawn-balance: uint, ;; Amount of STX tokens that have already been withdrawn by the recipient
        payment-per-block: uint, ;; How many STX tokens to unlock with each passing block
        timeframe: (tuple (start-block uint) (stop-block uint)) ;; Another tuple with two values, start-block and stop-block signifying the range of blocks during which this stream is active
    })
;;

;; public functions
(define-public (stream-to 
    ( recipient principal )
    ( initial-balance uint )
    ( timeframe (tuple (start-block uint) (stop-block uint)))
    ( payment-per-block uint )
    )
    (let (
        (stream {
            sender: contract-caller,
            recipient: recipient,
            balance: initial-balance,
            withdrawn-balance: u0,
            payment-per-block: payment-per-block,
            timeframe: timeframe
        }) 
        (current-stream-id (var-get latest-stream-id))
    ) 
    ;; stx-transfer takes in (amount, sender, recipient) arguments
    ;; for the `recipient` - we do `(as-contract tx-sender)`
    ;; `as-contract` switches the `tx-sender` variable to be the contract principal
    ;; inside it's scope
    ;; so doing `as-contract tx-sender` gives us the contract address itself
    ;; this is like doing address(this) in Solidity
    (try! (stx-transfer? initial-balance contract-caller (as-contract tx-sender)))
    (map-set streams current-stream-id stream)
    (var-set latest-stream-id (+ current-stream-id u1))
    (ok current-stream-id)
    )
)

;; Increase the locked STX balance for a stream
(define-public (refuel 
    (stream-id uint)
    (amount uint)
    )
    (let (
        (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
        )
    (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)

    (try! (stx-transfer? amount contract-caller (as-contract tx-sender)))

    (map-set streams stream-id
        (merge stream {balance: (+ (get balance stream) amount)})
    )
    (ok amount)
    )
)

(define-read-only (calculate-block-delta 
    (timeframe (tuple (start-block uint) (stop-block uint)))
    ) 
    (let (
        ( start-block (get start-block timeframe))
        ( stop-block (get stop-block timeframe))
        (delta 
            (if (<= block-height start-block) ;; block-height means the current number of blocks mined
                ;; then
                u0 ;; i.e. stream is not active
                ;; else
                (if (< block-height stop-block)
                    ;; then
                    (- block-height start-block) ;; stream is not completed
                    ;; else
                    (- stop-block start-block) ;; stream is completed
                )
            )
        )
    )
    delta
    )
)

(define-read-only (balance-of 
    (stream-id uint)
    (who principal)
    )
    (let (
        ( stream (unwrap! (map-get? streams stream-id) u0))
        (block-delta (calculate-block-delta (get timeframe stream)))
        (recipient-balance (* block-delta (get payment-per-block stream)))
    )
        (if (is-eq who (get recipient stream)) 
            (- recipient-balance (get withdrawn-balance stream))
            (if (is-eq who (get sender stream))
                (- (get balance stream) recipient-balance)
                u0
            )
        )
    )
)

;; Withdraw received tokens
(define-public (withdraw 
    (stream-id uint)
    )
    (let (
        (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
        (balance (balance-of stream-id contract-caller))
    )
        (asserts! (is-eq contract-caller (get recipient stream)) ERR_UNAUTHORIZED)
        (map-set streams stream-id
            (merge stream {withdrawn-balance: (+ (get withdrawn-balance stream) balance )})
        )
        (try! (as-contract (stx-transfer? balance tx-sender (get recipient stream))))
        (ok balance)
    )
)

;; Withdraw excess locked tokens
(define-public (refund (stream-id uint))
    (let (
        (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
        (balance (balance-of stream-id (get sender stream)))
    )
        (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)
        (asserts! (< (get stop-block (get timeframe stream)) block-height) ERR_STREAM_STILL_ACTIVE) ;; block-height means the current number of blocks mined
        (map-set streams stream-id
            (merge stream {balance: (- (get balance stream) balance )})
        )
        (try! (as-contract (stx-transfer? balance tx-sender (get sender stream))))
        (ok balance)
    )
)

;; Get hash of stream
(define-read-only (hash-stream 
    (stream-id uint)
    (new-payment-per-block uint)
    (new-timeframe (tuple (start-block uint) (stop-block uint)))
    )
    (let (
        (stream (unwrap! (map-get? streams stream-id) (sha256 0)))
        (msg (concat (concat (unwrap-panic (to-consensus-buff? stream)) (unwrap-panic (to-consensus-buff? new-payment-per-block))) (unwrap-panic (to-consensus-buff? new-timeframe))))
        )
        (sha256 msg)
    )
)

;; Signature Verification
(define-read-only (validate-signature 
        (hash (buff 32))
        (signature (buff 65))
        (signer principal)
    )
    (is-eq 
        (principal-of? (unwrap! (secp256k1-recover? hash signature) false))
        (ok signer)
    )
)

;; Update stream configuration
(define-public (update-details
        (stream-id uint)
        (payment-per-block uint)
        (timeframe (tuple (start-block uint) (stop-block uint)))
        (signer principal)
        (signature (buff 65))
    )
    (let (
        (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
    )
    (asserts! (validate-signature (hash-stream stream-id payment-per-block timeframe) signature signer) ERR_INVALID_SIGNATURE)
    (asserts! 
        (or
            (and (is-eq (get sender stream) contract-caller) (is-eq (get recipient stream) signer))
            (and (is-eq (get sender stream) signer) (is-eq (get recipient stream) contract-caller))
        )
        ERR_UNAUTHORIZED
    )
    (map-set streams stream-id (merge stream {
        payment-per-block: payment-per-block,
        timeframe: timeframe
    }))
    (ok true)
    )
)
;;

;; read only functions
;;

;; private functions
;;

