"""Build test/fixtures/r7_scrape_benchmark.json from the read-only r7 acceptance DB.

Labels:
  handoff   - IDs stated in docs/KONATA_R7_SCRAPING_HANDOFF_20261111.md (A/B/C).
  inspected - chosen by reading the saved candidates (title, year, episode counts).
  r7        - r7 confirmed binding, kept unless overridden above.
A missing key in "expect" means "unknown, not scored".
"""
import json, sqlite3, posixpath

DB = r"D:/Codex-Projects/Konata/release/validation/milky-acceptance-20261111-r7/Konata-Milky-Test-Windows-x64/userdata/scraper-library-auto/ccplayer.db"
OUT = r"D:/Codex-Projects/Konata/test/fixtures/r7_scrape_benchmark.json"

# path suffix -> expectation. tmdb: "movie:ID" | "tv:ID" | None. season: int. bangumi: ID | None.
H = "handoff"; I = "inspected"
OVERRIDES = {
    "Wake Up, Girls! 七人的偶像": dict(tmdb="movie:249766", bangumi=87700, src=I),
    "Wake Up, Girls! 新章": dict(tmdb="tv:74191", season=2, bangumi=201212, src=I),
    "Wake Up, Girls! 超越深限": dict(tmdb="movie:334361", bangumi=128801, src=I),
    "Wake Up, Girls! 青春之影": dict(tmdb="movie:357413", bangumi=119985, src=I),
    "伊藤计划三部曲/和谐": dict(tmdb="movie:357411", bangumi=100448, src=I),
    "伊藤计划三部曲/尸者的帝国": dict(tmdb="movie:342588", bangumi=118784, src=H),
    "伊藤计划三部曲/虐杀器官": dict(tmdb="movie:357407", bangumi=100447, src=H),
    "信长的忍者 伊势·金崎篇": dict(tmdb="tv:68146", season=2, bangumi=209839, src=I),
    "信长的忍者 姊川·石山篇": dict(tmdb="tv:68146", season=3, bangumi=235421, src=I),
    "全金属狂潮 Invisible Victory": dict(tmdb="tv:39379", season=4, bangumi=150246, src=I),
    "全金属狂潮 校园篇": dict(tmdb="tv:39379", season=2, bangumi=338, src=I),
    "剧场版 吸血鬼仆人 Alice in the Garden": dict(tmdb="movie:492715", src=I),
    "圣斗士星矢作品集/圣斗士星矢": dict(tmdb="tv:42444", bangumi=4843, src=I),
    "圣斗士星矢 圣域传说": dict(tmdb="movie:287590", bangumi=38228, src=H),
    "圣斗士星矢 圣域传说/Sample": dict(tmdb=None, bangumi=None, src=H),
    "圣斗士星矢 最终圣战的战士们": dict(tmdb="movie:83088", bangumi=27479, src=H),
    "圣斗士星矢 真红少年传说": dict(tmdb="movie:66105", bangumi=27478, src=H),
    "圣斗士星矢 神与神的激战": dict(tmdb="movie:83091", bangumi=27362, src=H),
    "圣斗士星矢 邪神厄里斯": dict(tmdb="movie:83090", bangumi=27361, src=H),
    "地狱少女系列/地狱少女": dict(tmdb="tv:8974", bangumi=1260, src=I),
    "头文字D Extra Stage (2001) {tmdb-40424}": dict(tmdb="tv:40424", season=0, bangumi=44758, src=H),
    "{tmdb-271709}": dict(tmdb="movie:271709", src=H),
    "{tmdb-321487}": dict(tmdb="movie:321487", src=H),
    "{tmdb-372758}": dict(tmdb="movie:372758", src=H),
    "奇诺之旅 活着的目标 -活下去。-": dict(bangumi=10582, src=I),
    "奇诺之旅 疾病之国 -为了你-": dict(tmdb="movie:833013", src=I),
    "女皇之刃 美丽女斗士们 (2010) {tmdb-45502}": dict(tmdb="tv:45502", season=0, bangumi=8389, src=H),
    "女皇之刃 魔法之书": dict(tmdb="tv:108589", bangumi=134951, src=I),
    "传心 守护月天！": dict(bangumi=207622, src=I),
    "幽游白书系列/幽游白书": dict(tmdb="tv:30669", bangumi=8803, src=I),
    "幽游白书 冥界死斗篇 炎之绊": dict(tmdb="movie:45279", bangumi=8804, src=H),
    "幽游白书 夜叉的阴谋": dict(tmdb="movie:45278", bangumi=8805, src=H),
    "弹丸论破 希望学园与绝望高中生": dict(tmdb="tv:49471", season=1, bangumi=56093, src=I),
    "超级弹丸论破2.5 狛枝凪斗与世界的破坏者": dict(tmdb="movie:1192735", bangumi=193911, src=I),
    "快盗天使系列/快盗天使双胞胎": dict(tmdb=None, bangumi=22599, src=H),
    "快盗天使双胞胎~心跳不已☆甜蜜天堂!!~": dict(tmdb=None, bangumi=10761, src=I),
    "拜托了双子星": dict(bangumi=1852, src=I),
    "拜托了老师": dict(tmdb="tv:19780", bangumi=297, src=I),
    "新妹魔王的契约者系列/新妹魔王的契约者": dict(tmdb="tv:64163", season=1, bangumi=100205, src=H),
    "新妹魔王的契约者 BURST": dict(tmdb="tv:64163", season=2, bangumi=128885, src=H),
    "新妹魔王的契约者 DEPARTURES": dict(tmdb="movie:507732", bangumi=228625, src=I),
    "新撰组异闻录 铁 ～友命～": dict(bangumi=241188, src=I),
    "新撰组异闻录 铁 ～想道～": dict(bangumi=178648, src=I),
    "{tmdb-21730}": dict(tmdb="tv:21730", season=0, bangumi=39530, src=H),
    "{tmdb-22914}": dict(tmdb="movie:22914", bangumi=2772, src=H),
    "{tmdb-508108}": dict(tmdb=None, src=H),
    "{tmdb-19256}": dict(tmdb="movie:19256", bangumi=5378, src=H),
    "{tmdb-19257}": dict(tmdb="movie:19257", bangumi=18778, src=H),
    "机动战士Z高达Ⅲ A New Translation -星辰的鼓动是爱-": dict(tmdb="movie:30606", src=I),
    "{tmdb-883768}": dict(tmdb="movie:883768", bangumi=349442, src=H),
    "机动战士高达 暮光的阿克西斯 赤红残影": dict(tmdb="movie:580799", bangumi=226561, src=I),
    "{tmdb-16157}": dict(tmdb="movie:16157", bangumi=4583, src=H),
    "{tmdb-1520936}": dict(tmdb="movie:1520936", bangumi=464293, src=H),
    "{tmdb-685274}": dict(tmdb="movie:685274", bangumi=243429, src=H),
    "闪光的哈萨维 喀耳刻的魔女": dict(tmdb="movie:910850", bangumi=243430, src=H),
    "雷霆宙域 BANDIT FLOWER": dict(tmdb="movie:468690", bangumi=219952, src=H),
    "雷霆宙域 DECEMBER SKY": dict(tmdb="movie:404114", bangumi=180172, src=H),
    "{tmdb-37048}": dict(tmdb="movie:37048", bangumi=5972, src=H),
    "{tmdb-45835}": dict(tmdb="tv:45835", season=0, bangumi=65601, src=H),
    "{tmdb-703527}": dict(tmdb="movie:703527", bangumi=17758, src=H),
    "机动战士高达 作品集/机动战士高达NT": dict(tmdb="movie:553610", bangumi=243428, src=H),
    "{tmdb-45148}": dict(tmdb="tv:45148", bangumi=10797, src=H),
    "{tmdb-101719}": dict(tmdb="tv:101719", bangumi=42789, src=H),
    "机动战士高达 作品集/高达之环": dict(tmdb="movie:705948", bangumi=101737, src=I),
    "机动战士高达 作品集/高达创形者": dict(tmdb="tv:76821", bangumi=236790, src=I),
    "高达创形者 再起": dict(tmdb="tv:76821", season=2, bangumi=286123, src=I),
    "高达创战者 Battlogue": dict(bangumi=214710, src=I),
    "相聚一刻系列/相聚一刻": dict(tmdb="tv:43018", bangumi=2921, src=I),
    "相聚一刻 完结篇": dict(tmdb="movie:301515", bangumi=530, src=I),
    "秀逗魔导士EVOLUTION-R (2009) {tmdb-26318}": dict(tmdb="tv:26318", season=5, bangumi=323, src=H),
    "剧场版 窈窕淑女": dict(tmdb=None, bangumi=None, src=I),
    "闪乱神乐 SHINOVI MASTER -东京妖魔篇-": dict(tmdb="tv:46065", season=2, src=I),
    "剧场版 黑子的篮球 终极一战": dict(tmdb="movie:428707", bangumi=147147, src=H),
    "剧场版 创圣的大天使": dict(tmdb=None, bangumi=None, src=H),
}
# Mixed folders whose correct identity is not a single provider entry.
UNSCORED = {"弹丸论破系列/弹丸论破3"}
# Several folders share one TMDB marker; key overrides by the full folder name.
KEYFIX = {
    "{tmdb-271709}": "头文字D Legend1 -觉醒- (2014) {tmdb-271709}",
    "{tmdb-321487}": "头文字D Legend2 -斗走- (2015) {tmdb-321487}",
    "{tmdb-372758}": "头文字D Legend3 -梦现- (2016) {tmdb-372758}",
    "{tmdb-21730}": "新机动战记高达W 无尽的华尔兹 (1997) {tmdb-21730}",
    "{tmdb-22914}": "新机动战记高达W 无尽的华尔兹 剧场版 (1998) {tmdb-22914}",
    "{tmdb-508108}": "机动战士SD高达 (1988) {tmdb-508108}",
    "{tmdb-19256}": "机动战士Z高达 A New Translation -星之继承者- (2005) {tmdb-19256}",
    "{tmdb-19257}": "机动战士Z高达Ⅱ A New Translation -恋人们- (2005) {tmdb-19257}",
    "{tmdb-883768}": "机动战士高达 库库鲁斯·杜安之岛 (2022) {tmdb-883768}",
    "{tmdb-16157}": "机动战士高达 逆袭的夏亚 (1988) {tmdb-16157}",
    "{tmdb-1520936}": "小挑战者的踪迹 (2025) {tmdb-1520936}",
    "{tmdb-685274}": "机动战士高达 闪光的哈萨维 (2021) {tmdb-685274}",
    "{tmdb-37048}": "机动战士高达00 先驱者的觉醒 (2010) {tmdb-37048}",
    "{tmdb-45835}": "机动战士高达AGE MEMORY OF EDEN (2013) {tmdb-45835}",
    "{tmdb-703527}": "机动战士高达MS IGLOO 2 重力战线 (2008) {tmdb-703527}",
    "{tmdb-45148}": "模型战士高达模型制作家 起始G (2010) {tmdb-45148}",
    "{tmdb-101719}": "高达 EVOLVE (2001) {tmdb-101719}",
}
OVERRIDES = {KEYFIX.get(k, k): v for k, v in OVERRIDES.items()}

def strip_candidate(c):
    out = {"id": c["id"], "type": c.get("type"), "title": c.get("title"), "year": c.get("year"),
           "aliases": c.get("aliases") or []}
    if c.get("seasons"):
        out["seasons"] = [[s["season"], s["count"], s.get("year")] for s in c["seasons"]]
    return out

conn = sqlite3.connect(f"file:///{DB}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
works = conn.execute("""SELECT w.id, l.relative_path AS path FROM works w
    JOIN library_locations l ON l.kind='work' AND l.entity_id=w.id ORDER BY l.relative_path""").fetchall()
result, used = [], set()
for w in works:
    path = w["path"]
    files = []
    for a in conn.execute("SELECT relative_path, size FROM assets WHERE work_id=? ORDER BY relative_path", (w["id"],)):
        rel = a["relative_path"]
        rel = posixpath.relpath(rel, path) if rel.startswith(path + "/") else posixpath.basename(rel)
        files.append([rel, a["size"]])
    entry = {"path": path, "files": files, "tmdb": [], "bangumi": [], "r7": {}, "expect": {}}
    for b in conn.execute("SELECT provider, state, reason, candidates, adopted FROM scan_bindings WHERE work_id=? AND layer='work'", (w["id"],)):
        entry[b["provider"]] = [strip_candidate(c) for c in json.loads(b["candidates"])]
        adopted = json.loads(b["adopted"]) if b["adopted"] else None
        entry["r7"][b["provider"]] = f"{b['state']}:{b['reason']}" + (f":{adopted.get('type')}:{adopted['id']}" if adopted else "")
        if b["state"] == "confirmed" and adopted:
            if b["provider"] == "tmdb":
                entry["expect"]["tmdb"] = f"{adopted['type']}:{adopted['id']}"
            else:
                entry["expect"]["bangumi"] = adopted["id"]
            entry["expect"]["src"] = "r7"
    rng = conn.execute("SELECT adopted FROM scan_bindings WHERE work_id=? AND layer='range' AND provider='tmdb' AND state='confirmed' AND scope=''", (w["id"],)).fetchone()
    if rng and rng["adopted"] and entry["expect"].get("tmdb", "").startswith("tv:"):
        entry["expect"]["season"] = json.loads(rng["adopted"]).get("season")
    best = None
    for key in OVERRIDES:
        if path.endswith(key):
            if best is None or len(key) > len(best):
                best = key
    if best:
        assert best not in used, ("override matches several works", best, path)
        used.add(best)
        exp = dict(OVERRIDES[best])
        if "season" not in exp and exp.get("tmdb") != entry["expect"].get("tmdb"):
            entry["expect"].pop("season", None)
        entry["expect"].update(exp)
    if any(path.endswith(u) for u in UNSCORED):
        entry["expect"] = {}
    result.append(entry)

missing = set(OVERRIDES) - used
assert not missing, missing
with open(OUT, "w", encoding="utf-8") as f:
    json.dump({"note": "Derived read-only from Konata r7 acceptance DB (182 works). See tool/build_r7_fixture notes in test.",
               "works": result}, f, ensure_ascii=False, separators=(",", ":"))
print("works", len(result), "labelled tmdb", sum(1 for r in result if "tmdb" in r["expect"]),
      "labelled bangumi", sum(1 for r in result if "bangumi" in r["expect"]))
import os; print("bytes", os.path.getsize(OUT))
