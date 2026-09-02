set -eu
settle=bin/fm-pr-attestation-settle.sh
# Unreachable while the checkout above takes the default merge ref:
# that tree always carries what main carries. This exists so that
# re-pinning ref:, or any other split between this workflow's
# definition and the tree it runs against, reports its cause instead
# of exiting 127 naming nothing - which is how it failed the first
# time, on a check whose whole purpose is to be trusted.
if [ ! -x "$settle" ]; then
  echo "::error::$settle is absent from the checked-out tree, so this step cannot run."
  echo "This workflow's definition comes from head merged into base, but its files come from whatever ref the checkout step selects; those must be the same tree."
  echo "If the checkout above pins a ref:, remove it so the default merge ref is used."
  echo "If it does not, this branch predates the commit that added $settle - rebase it onto main."
  exit 1
fi
"$settle" \
  --repo "$GITHUB_REPOSITORY" \
  --pr "$PR_NUMBER" \
  --event "$PR_EVENT" \
  --output "$GITHUB_OUTPUT"

