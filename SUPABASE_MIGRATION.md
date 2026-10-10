# Supabase: skupiny a bezpečný priebeh hodiny

## Stav nasadenia

Migrácie boli úspešne aplikované na produkčný slovenský projekt `ifrs-t-sk`
10. októbra 2026:

- `20261010183930 groups_and_safe_workflow`
- `20261010184028 groups_advisor_fixes`

Databáza je pripravená na nasadenie frontendu z pull requestu č. 1.

## Pred nasadením

1. V Supabase vytvorte databázovú zálohu alebo export tabuľky `public.proposals`.
2. Overte, že v Authentication sú zapnuté anonymné prihlásenia.
3. Overte existenciu účtov:
   - `tumpach@vutbr.cz`
   - `lenka.uzikova@euba.sk`
   - `zuzana.uzikova@euba.sk`
4. Najskôr spustite SQL migráciu, až potom nasaďte nový `index.html`.

Migrácia: `supabase/migrations/20261010_groups_and_safe_workflow.sql`

Migrácia nemení uvedené používateľské účty. Vytvorí skupiny `UA01` až `UA05`, `AKT01` a archívnu skupinu `UAXX`. Všetky záznamy, ktoré existovali pred migráciou, dostanú `group_id = 'UAXX'`. Nové aktívne skupiny preto začínajú prázdne.

## Dôležité správanie

- Učitelia majú po migrácii prístup ku všetkým skupinám.
- `UAXX` je iba archív; nové odpovede ani nové zadania nepovoľuje.
- Nové zadanie automaticky zastaví prijímanie odpovedí. Učiteľ ho musí vedome zapnúť.
- Schválenie konsenzu je jedna databázová transakcia a následne prijímanie odpovedí zastaví.
- Študent môže čítať iba verejné schválené zadania a svoje vlastné pokusy v zvolenej skupine.
- Importované XLSX prípady sú uložené v Supabase podľa skupiny a roka, nie iba v prehliadači.

## Kontrola po migrácii

Spustite v SQL Editore:

```sql
select code, name, is_archive from public.study_groups order by code;

select group_id, count(*)
from public.proposals
group by group_id
order by group_id;

select u.email, array_agg(a.group_id order by a.group_id) as groups
from public.teacher_group_access a
join auth.users u on u.id = a.teacher_user_id
group by u.email
order by u.email;

select group_id, year, current_case_number, accepting_answers
from public.group_year_state
order by group_id, year;
```

Očakávaný výsledok:

- staré záznamy sú iba v `UAXX`,
- každý z troch učiteľov má sedem priradených skupín,
- každá skupina má stav pre roky `20X1`, `20X2`, `20X3`,
- všetky skupiny majú po migrácii prijímanie odpovedí vypnuté.

## Test pred produkčným použitím

1. Prihláste sa ako učiteľ a zvoľte `UA01`.
2. Importujte malý XLSX súbor pre `20X1`.
3. Publikujte prvý prípad a zapnite prijímanie odpovedí.
4. V anonymnom okne otvorte stránku s `?group=UA01` a odošlite návrh.
5. Prepnite anonymné okno na `UA02`; návrh z `UA01` sa nesmie zobraziť.
6. Zastavte odpovede a overte, že databáza ďalší návrh odmietne aj zo starej otvorenej karty.
7. Schváľte konsenzus a overte, že sa vytvoril iba jeden schválený zápis.
8. Skontrolujte `UAXX`; musí obsahovať pôvodné dáta a nesmie umožniť nový zápis.

## Návrat aplikácie späť

Pred migráciou je nutná záloha. SQL migrácia sprísňuje RLS a dopĺňa povinný `group_id`, preto sa návrat nemá robiť iba nasadením starého HTML. Pri návrate obnovte databázovú zálohu aj predchádzajúcu verziu aplikácie spoločne.

