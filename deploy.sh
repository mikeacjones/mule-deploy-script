#!/bin/sh
CURRENT_POLICY_VERSION=2.1.10
read -p "Connected App client_id: " anypoint_client_id
read -sp "Connected App client_secret: " anypoint_client_secret

echo ""
read -p "Business group to deploy to (ALL for all business groups, or LIST for interactive selection): " business_group
read -p "Apply automated policy automatically? [y|n]: " apply_policy
if [ "$apply_policy" == "y" ] || [ "$apply_policy" == "Y" ]; then
read -p "Apply automated policy in production? [y|n]: " apply_policy_production
fi

# GET ACCESS TOKEN FOR CONNECTED APP
access_token=$(
curl -s -X POST https://anypoint.mulesoft.com/accounts/api/v2/oauth2/token \
-H 'Content-Type: application/json' \
-d '{"client_id":"'$anypoint_client_id'","client_secret":"'$anypoint_client_secret'","grant_type":"client_credentials"}' \
| jq -r '.access_token' \
)
echo $access_token
read -n1

# IF DOING ALL BUSINESS GROUPS, CALL /me AND ADD ALL BUSINESS GROUP IDs TO ARRAY
if [ "$business_group" == "ALL" ] || [ "$business_group" == "all" ]; then
business_groups=()
jsonData=$(curl -s https://anypoint.mulesoft.com/accounts/api/me \
-H "Authorization: Bearer $access_token" \
-H "Accept: application/json")

for k in $(echo $jsonData | jq '.user.contributorOfOrganizations | keys | .[]'); do
business_groups+=($(echo $jsonData | jq -r ".user.contributorOfOrganizations[$k].id"))
done
# IF DOING LIST, CALL /me AND THEN LIST BUSINESS GROUP IDS. AS USER TYPES INDEX OF BUSINESS GROUP, UUID IS ADDED TO ARRAY
# CURRENTLY NO WAY TO REMOVE A BUSINESS GROUP ONCE SELECTED OTHER THAN RESTARTING THE SCRIPT
# TYPE Q OR q WHEN DONE ADDING BUSINESS GROUP
elif [ "$business_group" == "LIST" ] || [ "$business_group" == "list" ]; then
business_groups=()
jsonData=$(curl -s https://anypoint.mulesoft.com/accounts/api/me \
-H "Authorization: Bearer $access_token" \
-H "Accept: application/json")

for k in $(echo $jsonData | jq '.user.contributorOfOrganizations | keys | .[]'); do
echo "$k: $(echo $jsonData | jq -r ".user.contributorOfOrganizations[$k].name")"
done
echo "Q: Done and deploy"

while read -n1 -r -p "Enter business group index: " && [[ $REPLY != q && $REPLY != Q ]]; do
business_groups+=($(echo $jsonData | jq -r ".user.contributorOfOrganizations[$REPLY].id"))
echo ""
done
elif [ "$business_group" == "" ]; then
exit
# THE ASSUMPTION HERE IS THAT THEY PROVIDED THE UUID FOR A SINGLE BUSINESS GROUP
else
business_groups=($business_group)
fi

export ANYPOINT_TOKEN=$access_token

echo "\nStarting deployment..."

for bgi in ${business_groups[@]}; do
#sed -i '' "s|[0-9a-zA-Z_-]\{1,\}|$bgi|g" pom.xml
sed -i ''"6s/.*/<groupId>$bgi</groupId>" pom.xml
echo $bgi
read -n1
#mvn clean deploy -B -s settings.xml | grep "status code"
docker run -it --rm --name my-maven-project -v "$(pwd)":/usr/src/mymaven -w /usr/src/mymaven maven:3.8.1-adoptopenjdk-15 /bin/bash -c "mvn clean deploy -s settings.xml"

# IF THEY SAID YES TO ADDING TO AUTOMATED POLICY...
if [[ "$apply_policy" == "y" || "$apply_policy" == "Y" ]]; then
# FIRST BUILD OUR DEFAULT CONFIG
jsonData=$(curl -s "https://anypoint.mulesoft.com/apimanager/xapi/v1/organizations/$bgi/exchange-policy-templates/$bgi/noname-security/$CURRENT_POLICY_VERSION" \
-H "Accept: application/json" \
-H "Authorization: Bearer $access_token")
configJson="{"
for k in $(echo $jsonData | jq '.configuration | keys | .[]'); do
if [ "$k" != "0" ]; then
configJson+=","
fi
if [ "$(echo $jsonData | jq -r ".configuration[$k].type")" != "string" ]; then
configJson+="\"$(echo $jsonData | jq -r ".configuration[$k].propertyName")\":$(echo $jsonData | jq -r ".configuration[$k].defaultValue")"
else
configJson+="\"$(echo $jsonData | jq -r ".configuration[$k].propertyName")\":\"$(echo $jsonData | jq -r ".configuration[$k].defaultValue")\""
fi
done
configJson+="}"

# GET ALL OF THE ENVIRONMENTS FOR THIS BUSINESS GROUP
environments=()
jsonData=$(curl -s "https://anypoint.mulesoft.com/accounts/api/organizations/$bgi/environments" \
-H "Accept: application/json" \
-H "Authorization: Bearer $access_token")
for k in $(echo $jsonData | jq '.data | keys | .[]'); do
if [ "$(echo $jsonData | jq -r ".data[$k].type")" != "design" ]; then
if ([ "$apply_policy_production" == "y" ] || [ "$apply_policy_production" == "Y" ] || [ "$(echo $jsonData | jq -r ".data[$k].isProduction")" == "false" ]); then
environments+=($(echo $jsonData | jq -r ".data[$k].id"))
fi
fi
done

# NEXT, CREATE THE AUTOMATED POLICY IN EACH ENVIRONMENT
for eid in ${environments[@]}; do
automated_policy_payload="{\"configurationData\":$configJson,\"pointcutData\":null,\"ruleOfApplication\":{\"environmentId\":\"$eid\",\"organizationId\":\"$bgi\",\"range\":{\"from\":\"4.1.1\"}}, \"groupId\": \"$bgi\",\"assetId\": \"noname-security\",\"assetVersion\":\"$CURRENT_POLICY_VERSION\"}"
result=$(curl -s -X POST "https://anypoint.mulesoft.com/apimanager/api/v1/organizations/$bgi/automated-policies" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $access_token" \
-d "$automated_policy_payload")
done
fi

echo "Finished deployment to business group $bgi"
done
echo "\nDeployment complete"
