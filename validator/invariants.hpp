/*
    This file is part of TON Blockchain Library.

    TON Blockchain Library is free software: you can redistribute it and/or modify
    it under the terms of the GNU Lesser General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    TON Blockchain Library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public License
    along with TON Blockchain Library.  If not, see <http://www.gnu.org/licenses/>.

    Copyright 2017-2020 Telegram Systems LLP
*/
#pragma once

#include "validator/interfaces/block-handle.h"

// Save TON's UNREACHABLE() before including the Antithesis SDK, which
// defines its own UNREACHABLE(message, ...) macro.
#pragma push_macro("UNREACHABLE")
#undef UNREACHABLE
#include "antithesis_sdk.h"
// Restore TON's UNREACHABLE() so the rest of the codebase is unaffected.
#pragma pop_macro("UNREACHABLE")

namespace ton {

namespace validator {

class ValidatorInvariants {
 public:
  static void check_post_apply(BlockHandle handle) {
    REACHABLE("Post-apply invariant check reached", {{"block_id", handle->id().to_str()}});
    ALWAYS(handle->received_state(), "Block state received after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->received_state());
    ALWAYS(handle->inited_state_root_hash(), "Block state root hash initialized after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_state_root_hash());
    ALWAYS(handle->inited_logical_time(), "Block logical time initialized after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_logical_time());
    ALWAYS(handle->inited_unix_time(), "Block unix time initialized after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_unix_time());
    ALWAYS(handle->inited_split_after(), "Block split-after initialized after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_split_after());
    if (handle->id().seqno() > 0) {
      ALWAYS(handle->inited_proof() || handle->inited_proof_link(), "Block proof initialized after apply for non-genesis", {{"block_id", handle->id().to_str()}});
      CHECK(handle->inited_proof() || handle->inited_proof_link());
    }
    ALWAYS(handle->processed(), "Block marked processed after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->processed());
    ALWAYS(handle->is_applied(), "Block marked applied after apply", {{"block_id", handle->id().to_str()}});
    CHECK(handle->is_applied());
  }
  static void check_post_accept(BlockHandle handle) {
    REACHABLE("Post-accept invariant check reached", {{"block_id", handle->id().to_str()}});
    ALWAYS(handle->received(), "Block received after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->received());
    ALWAYS(handle->received_state(), "Block state received after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->received_state());
    ALWAYS(handle->inited_state_root_hash(), "Block state root hash initialized after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_state_root_hash());
    ALWAYS(handle->inited_merge_before(), "Block merge-before initialized after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_merge_before());
    ALWAYS(handle->inited_split_after(), "Block split-after initialized after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_split_after());
    ALWAYS(handle->inited_prev(), "Block prev initialized after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_prev());
    CHECK(handle->inited_state_root_hash());
    ALWAYS(handle->inited_logical_time(), "Block logical time initialized after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_logical_time());
    ALWAYS(handle->inited_unix_time(), "Block unix time initialized after accept", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_unix_time());
    if (handle->id().is_masterchain()) {
      ALWAYS(handle->inited_proof(), "Masterchain block proof initialized after accept", {{"block_id", handle->id().to_str()}});
      CHECK(handle->inited_proof());
      ALWAYS(handle->is_applied(), "Masterchain block applied after accept", {{"block_id", handle->id().to_str()}});
      CHECK(handle->is_applied());
      ALWAYS(handle->inited_is_key_block(), "Masterchain key block flag initialized after accept", {{"block_id", handle->id().to_str()}});
      CHECK(handle->inited_is_key_block());
    } else {
      ALWAYS(handle->inited_proof_link(), "Non-masterchain block proof link initialized after accept", {{"block_id", handle->id().to_str()}});
      CHECK(handle->inited_proof_link());
    }
  }
  static void check_post_check_proof(BlockHandle handle) {
    REACHABLE("Post-check-proof invariant check reached", {{"block_id", handle->id().to_str()}});
    ALWAYS(handle->inited_merge_before(), "Block merge-before initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_merge_before());
    ALWAYS(handle->inited_split_after(), "Block split-after initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_split_after());
    ALWAYS(handle->inited_prev(), "Block prev initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_prev());
    ALWAYS(handle->inited_state_root_hash(), "Block state root hash initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_state_root_hash());
    ALWAYS(handle->inited_logical_time(), "Block logical time initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_logical_time());
    ALWAYS(handle->inited_unix_time(), "Block unix time initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_unix_time());
    ALWAYS(handle->inited_proof(), "Block proof initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_proof());
    ALWAYS(handle->inited_is_key_block(), "Block key block flag initialized after proof check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_is_key_block());
  }
  static void check_post_check_proof_link(BlockHandle handle) {
    REACHABLE("Post-check-proof-link invariant check reached", {{"block_id", handle->id().to_str()}});
    ALWAYS(handle->inited_merge_before(), "Block merge-before initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_merge_before());
    ALWAYS(handle->inited_split_after(), "Block split-after initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_split_after());
    ALWAYS(handle->inited_prev(), "Block prev initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_prev());
    ALWAYS(handle->inited_state_root_hash(), "Block state root hash initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_state_root_hash());
    ALWAYS(handle->inited_logical_time(), "Block logical time initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_logical_time());
    ALWAYS(handle->inited_unix_time(), "Block unix time initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_unix_time());
    ALWAYS(handle->inited_proof_link(), "Block proof link initialized after proof link check", {{"block_id", handle->id().to_str()}});
    CHECK(handle->inited_proof_link());
  }
};

}  // namespace validator

}  // namespace ton
