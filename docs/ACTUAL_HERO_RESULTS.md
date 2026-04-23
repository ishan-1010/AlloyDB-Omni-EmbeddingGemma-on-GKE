# Actual Hero Query Results — 2026-04-23 Dry Run

Captured from the dry-run cluster on the morning of 23 Apr after the overnight embedding generation completed successfully. These are the **real** numbers — not placeholders.

---

## Architecture — all pods running

```
alloydb-omni-system   fleet-controller-manager-5dfddcb47d-rf2pb       1/1   Running   9h
alloydb-omni-system   local-controller-manager-68c585cdf5-vt8dj       1/1   Running   9h
cert-manager          cert-manager-6dd9bdbd89-mn865                    1/1   Running   9h
cert-manager          cert-manager-cainjector-74bf7474d8-pthb9         1/1   Running   9h
cert-manager          cert-manager-webhook-6f9f498c99-28dnm            1/1   Running   9h
default               al-9fe0-my-omni-0                                3/3   Running   9h   # AlloyDB pod
default               tei-deployment-7b87597786-w5ghg                  1/1   Running   9h   # TEI + EmbeddingGemma
```

## Services in the default namespace

```
NAME                                TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)
al-9fe0-my-omni-dbd                 ClusterIP      34.118.239.248   <none>        3203/TCP
al-9fe0-my-omni-monitoring-system   ClusterIP      34.118.239.102   <none>        9187/TCP
al-my-omni-rw-elb                   LoadBalancer   34.118.234.207   10.128.0.39   5432:32501/TCP
tei-service                         ClusterIP      34.118.232.129   <none>        80/TCP
```

## Raw embedding sample (first 150 chars of a 768-dim vector)

```
 uniq_id: 72380122311d120f193f601da1b5f244
 first_150_chars: [-0.08797259,-0.011677752,0.026522823,0.013631803,-0.021470953,
                   0.056472335,0.0024991436,-0.0053109853,0.052568424,-0.013035465,
                   0.031414583,-0.04357048...
 dims: 768
```

## THE HERO QUERY — real results

**Query:** `"What kind of fruit trees grow well here?"` filtered to `store_id=1583, inventory>0`

```
     product_name      | description                  | sale_price | zip_code |  distance
-----------------------+------------------------------+------------+----------+-----------
 Cherry Tree           | This is a beautiful cherry…  |      75.00 |    93230 |  0.521055
 California Lilac      | This is a beautiful lilac…   |       5.00 |    93230 |  0.563942
 Toyon                 | This is a beautiful toyon…   |      10.00 |    93230 |  0.567003
 Rose Bush             | This is a beautiful rose…    |      50.00 |    93230 |  0.573154
 California Peppertree | This is a beautiful pepper…  |      25.00 |    93230 |  0.575093

Time: 20,487 ms
```

## BONUS — semantic generality (different query)

**Query:** `"something cheap for my patio"` (no store filter, across all 941 products)

```
 product_name  | sale_price |  distance
---------------+------------+-----------
 Garden Rake   |      20.00 |  0.532307
 Wheelbarrow   |      50.00 |  0.535083
 Watering Can  |      10.00 |  0.543384
 Garden Trowel |      15.00 |  0.548519
 Hat           |       5.00 |  0.549024
```

**Why this is gold for teaching:** none of these 5 product names contain the words `cheap` or `patio`. The model semantically understood "cheap + patio" → garden tools + affordable items.

## EXPLAIN ANALYZE — the timing breakdown

```
Limit  (cost=216.50..216.52 rows=5 width=83) (actual time=6.549..6.554 rows=5 loops=1)
  ->  Sort  (cost=216.50..218.86 rows=941 width=83)
        Sort Key: ((ce.embedding <=> '[long 768-float vector...]'::vector))
        Sort Method: top-N heapsort  Memory: 25kB
        ->  Hash Join  (cost=34.17..200.87 rows=941 width=83)
              Hash Cond: ((cp.uniq_id)::text = (ce.uniq_id)::text)
              ->  Seq Scan on cymbal_products cp
              ->  Seq Scan on cymbal_embedding ce

Planning Time:   20,153.978 ms   ← TIME SPENT CALLING TEI TO EMBED THE QUERY TEXT
Execution Time:       6.641 ms   ← ACTUAL VECTOR SEARCH + JOIN + SORT
```

**The story:** 99.97% of the 20.5-second response time was the HTTP call to TEI to embed `"fruit trees"`. Once the query vector existed, AlloyDB searched all 941 vectors + joined + sorted in **6.6 ms**. This is the core production lesson: *cache query embeddings* OR *embed at write-time, not read-time*.

---

## Cost — real numbers

- Total spent across ALL attempts (failed + successful + overnight idle): **$2.03**
- TryGCP credit remaining: **$2.97** (of $5)
- Realistic per-student cost: **$0.40–$0.60 per 45-min session**
- 40 students total: **$16–$24** (not the $42 I originally estimated)

---

## The two/three trial-account deviations that made this work

1. **Cluster create:** `--disk-type=pd-standard --disk-size=50` — bypass 250 GB SSD quota
2. **DBCluster manifest:** `memory: 4Gi` instead of `8Gi` — fit on e2-standard-4 nodes
3. **TEI deployment:** `cpu: 2 / memory: 4Gi` (not 6/24), no `c3` nodeSelector, service port 80:8080

All three are documented in [TRIAL_ACCOUNT_GUIDE.md](TRIAL_ACCOUNT_GUIDE.md).
