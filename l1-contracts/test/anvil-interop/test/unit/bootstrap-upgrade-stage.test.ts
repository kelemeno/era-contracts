/**
 * Unit tests for the bootstrap bundle's closing rule (`assertBundleClosesWithMigrate` in
 * `src/helpers/bootstrap-upgrade-stage.ts`): the bundle closes with `migrate()` on the migration,
 * and nothing runs after it — the edge's post-state is asserted by the runner after the replay.
 *
 * The rule compares target, value and calldata bytes without decoding, so the calldata here is an
 * opaque 4-byte tag standing in for `migrate()`.
 *
 * Run with: yarn test:unit bootstrap-upgrade-stage
 */

import * as assert from "assert/strict";
import { ethers } from "ethers";
import { assertBundleClosesWithMigrate } from "../../src/helpers/bootstrap-upgrade-stage";
import type { GovernanceCall } from "../../src/helpers/governance-bundle";
import { createSuite } from "./harness";

const { test, run } = createSuite("bootstrap-upgrade-stage");

const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

const MIGRATION = address(0xb0);
const CTM = address(0xc7);
// Stand-ins for `migrate()`, the retired completion check that used to follow it, and a handover.
const MIGRATE = "0xaabbccdd";
const RETIRED_COMPLETION_CHECK = "0x11223344";
const TRANSFER_OWNERSHIP = "0x55667788";

const call = (target: string, data: string, value = 0): GovernanceCall => ({
  target,
  value: ethers.BigNumber.from(value),
  data,
});

const HANDOVER = call(CTM, TRANSFER_OWNERSHIP);
const NOT_CLOSED = /the bootstrap bundle does not close with 0x[0-9a-fA-F]{40}\.migrate\(\)/;

test("accepts a bundle closing with migrate() on the migration", () => {
  assertBundleClosesWithMigrate([HANDOVER, call(MIGRATION, MIGRATE)], MIGRATION, MIGRATE);
});

test("compares the target and the calldata case-insensitively", () => {
  assertBundleClosesWithMigrate([call(MIGRATION.toLowerCase(), MIGRATE.toUpperCase())], MIGRATION, MIGRATE);
});

test("refuses an empty bundle", () => {
  assert.throws(() => assertBundleClosesWithMigrate([], MIGRATION, MIGRATE), /\(got an empty bundle\)/);
});

test("refuses a bundle that still runs the retired completion check after migrate()", () => {
  assert.throws(
    () =>
      assertBundleClosesWithMigrate(
        [HANDOVER, call(MIGRATION, MIGRATE), call(MIGRATION, RETIRED_COMPLETION_CHECK)],
        MIGRATION,
        MIGRATE
      ),
    new RegExp(`${NOT_CLOSED.source} \\(got target ${MIGRATION}, selector ${RETIRED_COMPLETION_CHECK}\\)`)
  );
});

test("refuses migrate() sent to another target", () => {
  assert.throws(() => assertBundleClosesWithMigrate([HANDOVER, call(CTM, MIGRATE)], MIGRATION, MIGRATE), NOT_CLOSED);
});

test("refuses a closing migrate() that carries value", () => {
  assert.throws(
    () => assertBundleClosesWithMigrate([HANDOVER, call(MIGRATION, MIGRATE, 1)], MIGRATION, MIGRATE),
    NOT_CLOSED
  );
});

run();
