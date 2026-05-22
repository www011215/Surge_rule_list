# Surge_rule_list

自用 rules，勿 fork

## Scripts

### `scripts/ipcheck.sh`

Focused IP-quality + streaming-region checker for proxy egress VPS. Tests v4 and v6 separately, then verifies any local smartdns force-family rules (Meta→v6, Google→v4) are in effect.

One-liner:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/www011215/Surge_rule_list/main/scripts/ipcheck.sh)
```

Flags: `-4` (v4 only) · `-6` (v6 only) · `-s` (skip DNS rule audit)
