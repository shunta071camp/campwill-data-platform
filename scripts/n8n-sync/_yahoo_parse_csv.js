// Yahoo Ads CSV を parse → raw.ec_yahoo_ads スキーマに正規化
// Search header:  Day,CampaignID,Campaign name,Impressions,Clicks,Cost,Conversions,Conv. value
// Display header: Daily,Campaign ID,Campaign Name,Impressions,Clicks,Cost,Conversions,Conv. value
// Display は末尾に Total 行があるのでスキップ

const rows = [];
const now = new Date().toISOString();

const norm = (s) => String(s || "").toUpperCase().replace(/[^A-Z0-9]/g, "");

const HEADER_ALIASES = {
  date:         ["DAY", "DAILY"],
  campaignId:   ["CAMPAIGNID"],
  campaignName: ["CAMPAIGNNAME"],
  impressions:  ["IMPRESSIONS", "IMPS"],
  clicks:       ["CLICKS"],
  cost:         ["COST"],
  conversions:  ["CONVERSIONS"],
  revenue:      ["CONVVALUE", "CONVERSIONVALUE"],
};

const findIdx = (header, aliases) => {
  for (const a of aliases) {
    const i = header.findIndex(h => norm(h) === a);
    if (i >= 0) return i;
  }
  return -1;
};

const inputItems = $input.all();
const extractItems = $('Extract Report Job IDs').all();

for (let inputIdx = 0; inputIdx < inputItems.length; inputIdx++) {
  const item = inputItems[inputIdx];
  const csvText = (typeof item.json === "string") ? item.json : (item.json.data || item.json.body || "");
  // Download HTTP ノードが $json を CSV body で上書きするので、Extract の同 index 出力から campaign_type 復元
  const original = extractItems[inputIdx];
  const campaignType = (original && original.json && original.json.campaign_type) || item.json.campaign_type || "unknown";
  if (!csvText || typeof csvText !== "string") continue;

  const lines = csvText.split(/\r?\n/).filter(l => l.trim().length > 0);
  if (lines.length < 2) continue;

  const header = lines[0].split(",").map(h => h.trim().replace(/"/g, ""));
  const idx = {
    date:         findIdx(header, HEADER_ALIASES.date),
    campaignId:   findIdx(header, HEADER_ALIASES.campaignId),
    campaignName: findIdx(header, HEADER_ALIASES.campaignName),
    impressions:  findIdx(header, HEADER_ALIASES.impressions),
    clicks:       findIdx(header, HEADER_ALIASES.clicks),
    cost:         findIdx(header, HEADER_ALIASES.cost),
    conversions:  findIdx(header, HEADER_ALIASES.conversions),
    revenue:      findIdx(header, HEADER_ALIASES.revenue),
  };

  for (let i = 1; i < lines.length; i++) {
    const fields = lines[i].split(",").map(f => f.trim().replace(/"/g, ""));
    const dayRaw = fields[idx.date];
    const cid = fields[idx.campaignId];

    if (!dayRaw || dayRaw === "Total" || dayRaw === "--") continue;
    if (!cid || cid === "--") continue;

    let date = dayRaw;
    if (/^\d{8}$/.test(dayRaw)) {
      date = dayRaw.slice(0, 4) + "-" + dayRaw.slice(4, 6) + "-" + dayRaw.slice(6, 8);
    }

    rows.push({
      date,
      campaign_id: cid,
      campaign_name: idx.campaignName >= 0 ? (fields[idx.campaignName] || null) : null,
      campaign_type: campaignType,
      ad_group_id: null,
      impressions: idx.impressions >= 0 ? Number(fields[idx.impressions]) : null,
      clicks:      idx.clicks >= 0 ? Number(fields[idx.clicks]) : null,
      cost:        idx.cost >= 0 ? Math.round(Number(fields[idx.cost])) : null,
      conversions: idx.conversions >= 0 ? Number(fields[idx.conversions]) : null,
      revenue:     idx.revenue >= 0 ? Math.round(Number(fields[idx.revenue])) : null,
      inserted_at: now
    });
  }
}

return rows.map(json => ({ json }));
