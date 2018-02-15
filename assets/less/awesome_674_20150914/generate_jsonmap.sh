# Nutne zmenit ve variables cestu k fontum a pouzit lokalni promenou misto te globalni co tam je.
# Po vygenerovani skriptu se to musi vratit zpet!!!!!
# Na konci json listu je potreba u posledniho hase odebrat carku

echo '
{
  "prefix": "fa-",
  "version": "4.4.0",
  "name": "FontAwesome",
  "icons": [
';

for i in $(lessc -c font-awesome.less | grep before | cut -f 1 -d ':' | cut -f 2- -d '-'); do

echo "	{"
echo "		\"name\": \"$i\""
echo "	},"

done

echo "	{ \"end\": 1 }
]}"
