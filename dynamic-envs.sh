#!/bin/bash

#
#Bash script to create/delete ALB rules and Route53 records for dynamic envs. Originally made for Codebuild, some Codebuild env variables are still used
#

#Defin necesary variables
export AWS_ACCOUNT_ID="XXXXX"
export CLUSTER="YourECSCluster"
export LOAD_BALANCER="YourLB"
export CONTAINER_PORT=3000
export REGION: us-east-1
export HOSTEDZONENAME: "YourDomainZone"
export VPC: "YourVPCID"

#Variables WEBHOOK_HEAD_REF or CODEBUILD_WEBHOOK_HEAD_REF comes from Codebuild webhook, must have been defined
export CODEBUILD_WEBHOOK_HEAD_REF=${CODEBUILD_WEBHOOK_HEAD_REF:-$WEBHOOK_HEAD_REF}
export CODEBUILD_WEBHOOK_BASE_REF=${CODEBUILD_WEBHOOK_BASE_REF:-$WEBHOOK_BASE_REF}

if [ -z $CODEBUILD_WEBHOOK_HEAD_REF ] && [ -z $WEBHOOK_HEAD_REF ]; then echo "Necessary variables not set"; exit 1; fi #Cannot continue work w/o CODEBUILD_WEBHOOK_HEAD_REF
if [ -z $CODEBUILD_WEBHOOK_BASE_REF ] && [ -z $WEBHOOK_BASE_REF ]; then export CODEBUILD_WEBHOOK_BASE_REF="dev"; fi #If no CODEBUILD_WEBHOOK_BASE_REF defined - then BASE_REF=dev

export REPO_NAME=$(basename -s .git `git config --get remote.origin.url`) #Name of Repository
export SERVICE_NAME=$(echo ${REPO_NAME} | cut -c 4-)                      #Name of Service
export IMAGE_TAG_FULL=${CODEBUILD_WEBHOOK_HEAD_REF##*/}                   #Full tag of HEAD_REF
export IMAGE_TAG=$(echo $IMAGE_TAG_FULL | sed -E 's/=?(FS-[0-9a-zA-Z]*).*/\1/' | tr '[:upper:]' '[:lower:]') # Short name of HEAD_REF
export IMAGE_TAG_FULL=$(echo $IMAGE_TAG_FULL | sed 's/[^a-zA-Z0-9\-]/_/g') # Escape characters in github tag name
export BASE_TAG="`echo ${CODEBUILD_WEBHOOK_BASE_REF} | cut -d \"/\" -f 3`" # Base tag of backend branch (still needed ?)
export IMAGE_REPO_NAME="cross-env-${SERVICE_NAME}"                         # Name of image in ECR
export MERGED_IMAGE_TAG="$BASE_TAG-$IMAGE_TAG"                             # combined name of DNS record, eg dev-f-fs-52384          
export CHECKOUT_TAG="$CODEBUILD_WEBHOOK_BASE_REF"

if [[ $CODEBUILD_WEBHOOK_HEAD_REF =~ ^(.*/)*(.*/.*)$ ]]; then export CHECKOUT_TAG=${BASH_REMATCH[2]}; fi #Get name of branch for Github checkout as last 2 parts of CODEBUILD_WEBHOOK_HEAD_REF
export BUILD_BRANCH=$IMAGE_TAG      # Build Branch

#configure env vars for building FE application
export APP_ENV=$IMAGE_TAG
export REACT_APP_WS_HOST=""
export REACT_APP_API_HOST=""
export REACT_APP_AUTH_COOKIES_DOMAIN=""
$(aws ecr get-login --no-include-email --region $REGION)   #Login to Docker

# show debug variables
echo "Debug information:"
echo "------------------------------------------------------------------"
echo "Source branch - CODEBUILD_WEBHOOK_HEAD_REF = '$CODEBUILD_WEBHOOK_HEAD_REF'"
echo "Source branch - IMAGE_TAG_FULL = '$IMAGE_TAG_FULL'"
echo "Image tag - IMAGE_TAG = '$IMAGE_TAG'"
echo "Base branch - BASE_TAG = '$BASE_TAG'"
echo "SERVICE_NAME = '$SERVICE_NAME'"
echo "Checkout TAG = '$CHECKOUT_TAG'"
#env | grep CODEBUILD

echo "------------------------------------------------------------------"
if [[ "$COMMAND" == "DELETE" ]]; then export CODEBUILD_WEBHOOK_EVENT="PULL_REQUEST_CLOSED"; fi #Update WEBHOOK_EVENT as COMMAND value
if [[ "$COMMAND" == "CREATE" ]]; then export CODEBUILD_WEBHOOK_EVENT="PULL_REQUEST_CREATED"; fi
if [[ "$COMMAND" == "UPDATE" ]]; then export CODEBUILD_WEBHOOK_EVENT="PULL_REQUEST_UPDATED"; fi
if [[ "$COMMAND" == "MERGE" ]]; then export CODEBUILD_WEBHOOK_EVENT="PULL_REQUEST_MERGED"; fi
if [[ ! -z "$COMMAND" && -z "$CODEBUILD_WEBHOOK_HEAD_REF" ]]; then echo "No WEBHOOK_HEAD_REF variable found!"; exit 1; fi  #Exit if no COMMAND defined

echo Build started on `date`
case "$CODEBUILD_WEBHOOK_EVENT" in #Setup COMMAND value based on EVENT
  PULL_REQUEST_CLOSED)
    export COMMAND="DELETE"
    ;;
  PULL_REQUEST_CREATE)
    export COMMAND="CREATE"
    ;;
  PULL_REQUEST_UPDATE)
    export COMMAND="UPDATE"
    ;;
  PULL_REQUEST_MERGED)
    export COMMAND="MERGE"
    ;;
esac

#Build Docker only on CREATE or UPDATE events
if [[ "$COMMAND" != "DELETE" && "$COMMAND" != "MERGE" ]]; then git checkout; echo "Running git checkout $CHECKOUT_TAG"; git checkout $CHECKOUT_TAG; fi #Checkout PR branch
if [[ "$COMMAND" != "DELETE" && "$COMMAND" != "MERGE" ]]; then 
  docker build --file Dockerfile.AWS \
        --build-arg REACT_APP_WS_HOST \
        --build-arg APP_ENV \
        --build-arg REACT_APP_API_HOST \
        --build-arg REACT_APP_AUTH_COOKIES_DOMAIN \
        --build-arg BUILD_BRANCH \
        -t $IMAGE_REPO_NAME:$IMAGE_TAG . ;
fi

#Tag/Push Docker only on CREATE or UPDATE events
if [[ "$COMMAND" != "DELETE" && "$COMMAND" != "MERGE" ]]; then docker tag $IMAGE_REPO_NAME:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG; fi
if [[ "$COMMAND" != "DELETE" && "$COMMAND" != "MERGE" ]]; then docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG; fi

export SERVICE="${IMAGE_TAG}-${SERVICE_NAME}" #Name of Dynamic env service in ECS
export ACTIVE_SERVICE=$(aws ecs list-services --cluster ${CLUSTER} | jq -r .[][] | sed 's:\([^/]*/\)*\(.*\):\2:' | grep -w ${SERVICE}) #Check if we have this service registered in ECS

echo "SERVICE is '${SERVICE}' ; ACTIVE_SERVICE is '${ACTIVE_SERVICE}'"

#Define Sub function to delete ECS service
        function delete_service() { 
          echo "Function delete_service() started"
          echo "Deleting service $SERVICE..."
          #Setting service desired-count to 0
          aws ecs update-service --region ${REGION} --cluster ${CLUSTER} --service ${SERVICE} --desired-count 0
          #Stoping all service tasks
          cmd="aws ecs list-tasks --cluster ${CLUSTER} --service-name ${SERVICE}"
          tasks=$($cmd | jq '.taskArns[]' | tr -d '"' | awk -e '{ s=gensub(/^.*\//, "","g"); print s}')
          for t in $tasks; do
            echo "Stopping task <$t>..."
            a=$(aws ecs stop-task --cluster ${CLUSTER} --task ${t})
          done 
          #Deleting service
          aws ecs delete-service --cluster ${CLUSTER} --service arn:aws:ecs:${REGION}:${AWS_ACCOUNT_ID}:service/${CLUSTER}/${SERVICE}
          #Deleting LB rule
          delete_LB_rules "*${IMAGE_TAG}.${REPO_NAME}.company.com"
          echo "Function delete_service() finished"
        }
        ##Define Sub function to update already registered ECS service
        function update_service() { 
          echo "Function update_service() started"
          SERVICE_ARN=`aws ecs update-service --region ${REGION} --cluster ${CLUSTER} --service ${SERVICE} --force-new-deployment | jq '.service.serviceArn'` #Restart service with new image
          if [[ ! -z "$SERVICE_ARN" ]]; then echo "Service updated ($SERVICE_ARN)" 
          else echo "Couldn't update service $SERVICE!"; fi
          echo "Function update_service() finished"
        }

##Define Sub function to delete LB rule
        function delete_LB_rules() { 
          echo "Function delete_LB_rules() started"
          if [[ -z "$1" ]]; then echo "No hostname specified; exiting..."; exit 1; fi
          HOSTNAME="$1"
          echo "Deleting LB rules for hostname $HOSTNAME..."
          LOAD_BALANCER_ARN=`aws elbv2 describe-load-balancers --names ${LOAD_BALANCER} | jq -r .LoadBalancers[].LoadBalancerArn` #Get ARN of LB
          if [[ -z "$LOAD_BALANCER_ARN" ]]; then echo "Couldn't find load balancer ARN!"; exit 1; fi
          LISTENER=`aws elbv2 describe-listeners --load-balancer ${LOAD_BALANCER_ARN} | jq -r ' .Listeners[] | select(.Port == 443) | .ListenerArn '` #Get Listener ARN
          if [[ -z "$LISTENER" ]]; then echo "Couldn't find LB Listener ARN!"; exit 1; 
          else echo "Listener ARN is $LISTENER!"; fi
          jqstr="aws elbv2 describe-rules --listener-arn ${LISTENER} | jq -r '.Rules[] | select(.Conditions[].HostHeaderConfig.Values[] == \"${HOSTNAME}\") | .RuleArn'"
          echo "Running command <<<${jqstr}>>>..."
          RULE_ARN=$(eval ${jqstr}) #Get ARN of LB rule
          if [[ ! -z "$RULE_ARN" ]]; then
            #Remove LB Rule
            aws elbv2 delete-rule --rule-arn ${RULE_ARN} 
            echo "LB Rule ${RULE_ARN} removed!"
          fi
          echo "Function delete_LB_rules() finished"

        }

#Define Sub function to create LB rule and target group
        function create_LB_rules() { 
          echo "Function create_LB_rules() started"
          if [[ -z "$1" ]]; then echo "No hostname specified; exiting..."; exit 1; fi
          HOSTNAME="$1"
          echo "Creating LB rules for hostname $HOSTNAME..."
          #Create JSON for LB rule conditions
          tee /tmp/conditions.json <<-EOF
          [{
            "Field": "host-header",
            "HostHeaderConfig": {
              "Values": ["${HOSTNAME}"]
            }
          }]
        EOF
          jqstr="aws elbv2 describe-rules --listener-arn ${LISTENER} | jq -r '.Rules[] | select(.Conditions[].HostHeaderConfig.Values[] == \"${HOSTNAME}\") | .RuleArn'"
          echo "Running command <<<${jqstr}>>>..."
          RULE_ARN=$(eval ${jqstr}) #Get ARN of rule with same condition
          #If rule found than delete it and create new with same priority
          if [[ ! -z "$RULE_ARN" ]]; then
            jqstr="aws elbv2 describe-rules --listener-arn ${LISTENER} | jq -r '.Rules[] | select(.Conditions[].HostHeaderConfig.Values[] == \"${HOSTNAME}\") | .Priority'"
            echo "Running command <<<$jqstr>>>..."
            RULE_PRIORITY=$(eval ${jqstr}) #Get priority of LB rule
            aws elbv2 delete-rule --rule-arn ${RULE_ARN} #Remove LB Rule
            echo "LB Rule ${RULE_ARN} removed!"
            LB_RULE=`aws elbv2 create-rule --listener-arn ${LISTENER}  --priority ${RULE_PRIORITY} --conditions file:///tmp/conditions.json --actions Type=forward,TargetGroupArn=${TARGET_GROUP} | jq -r .Rules[].RuleArn` #Create LB rule
            if [[ -z "$LB_RULE" ]]; then echo "Couldn't create LB rule"; exit 1; fi
          else
            #Else get last rule priority and insert rule with next priority
            LAST_RULE_PRIORITY=`aws elbv2 describe-rules --listener-arn ${LISTENER} | jq -r '.Rules[-2] |.Priority'` #Index [-2] is the last rule with number priority before "default"
            NEXT_PRIORITY="$((${LAST_RULE_PRIORITY}+1))" #Get next free priority
            LB_RULE=`aws elbv2 create-rule --listener-arn ${LISTENER}  --priority ${NEXT_PRIORITY} --conditions file:///tmp/conditions.json --actions Type=forward,TargetGroupArn=${TARGET_GROUP} | jq -r .Rules[].RuleArn` #Create LB rule
            if [[ -z "$LB_RULE" ]]; then echo "Couldn't create LB rule"; exit 1; fi
            echo "LB Rule ${LB_RULE} created!"
          fi
          echo "Function create_LB_rules() finished"
        }

#Define Sub function to Remove LB Rule
        function create_service() {
          echo "Function create_service() started"
          #Create task definition JSON
          TPL_FILE=${SERVICE_NAME}.json.tpl
          JSON_FILE=$SERVICE.json
          aws s3 cp s3://fh-dev-buildspec/templates/${TPL_FILE} ./${JSON_FILE} #Copy template for task definition and replace template values
          sed -i "s/%ENV%/${IMAGE_TAG}/g" ${JSON_FILE}
          sed -i "s/%FULL_ENV%/${IMAGE_TAG_FULL}/g" ${JSON_FILE}
          sed -i "s/%BASE_ENV%/${BASE_TAG}/g" ${JSON_FILE}
          #Register task definition
          TASK_DEF=`aws ecs register-task-definition --cli-input-json file://${JSON_FILE} | jq -r .taskDefinition.taskDefinitionArn` #Create Task Definition
          if [[ -z "$TASK_DEF" ]]; then echo "Couldn't register task defination!"; exit 1; else echo "TASK_DEF ARN is $TASK_DEF"; fi
          LOG_GROUP=`aws logs create-log-group --log-group-name /ecs/$SERVICE` #Create log-group
          LOAD_BALANCER_ARN=`aws elbv2 describe-load-balancers --names ${LOAD_BALANCER} | jq -r .LoadBalancers[].LoadBalancerArn` #Get LB ARN
          if [[ -z "$LOAD_BALANCER_ARN" ]]; then echo "Couldn't find load balancer ARN!"; exit 1; fi
          TARGET_GROUP=`aws elbv2 create-target-group --name ${SERVICE} --protocol HTTP --port 80 --vpc-id ${VPC} | jq -r .TargetGroups[].TargetGroupArn` #Create Target Group
          if [[ -z "$TARGET_GROUP" ]]; then echo "Couldn't register target group!"; exit 1; fi
          echo "Target Group $TARGET_GROUP created!"
          LISTENER=`aws elbv2 describe-listeners --load-balancer ${LOAD_BALANCER_ARN} | jq -r ' .Listeners[] | select(.Port == 443) | .ListenerArn '` #GET Listener ARN
          if [[ -z "$LISTENER" ]]; then echo "Couldn't find LB Listener ARN!"; exit 1; 
          else echo "Listener ARN is $LISTENER!"; fi
          create_LB_rules "*${IMAGE_TAG}.${REPO_NAME}.company.com" #Create LB rule for DNS record like dev-f-FS-12345.webapp.company.com
          #Create service
          SERVICE_ARN=`aws ecs create-service --cluster ${CLUSTER} --service-name ${SERVICE} --task-definition ${TASK_DEF} --desired-count 1 --load-balancers targetGroupArn=${TARGET_GROUP},containerName=${SERVICE},containerPort=${CONTAINER_PORT} | jq -r .service.serviceArn` #Create service with name $SERVICE
          if [[ -z "$SERVICE_ARN" ]]; then echo "Couldn't create service"; exit 1; fi
          echo "Service $SERVICE_ARN created!"
          echo "Function create_service() finished"
        }

#Main cycle begins here

#If EVENT="CREATE" - check if we need to create new service
if [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_CREATED" ]]; then 
  echo "Creating service ${SERVICE_NAME}"
  if [ -z ${ACTIVE_SERVICE} ];then
    create_service
  else 
    update_service
  fi
  #If EVENT="UPDATE" - update service or create it if needed
elif [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_UPDATED" ]]; then 
  echo "Updating service ${SERVICE_NAME}"
  if [ -z ${ACTIVE_SERVICE} ];then
    create_service
  else
    update_service
  fi
  #If EVENT="MERGED" = remove service
elif [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_MERGED" ]]; then 
  echo "Destroying service ${SERVICE_NAME}"
  if [ ! -z ${ACTIVE_SERVICE} ];then
    delete_service
  else
    echo "Service was already deleted"
  fi
  #If EVENT="CLOSE" = remove service
elif [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_CLOSED" ]]; then 
  echo "Destroying service ${SERVICE_NAME}"
  if [ ! -z ${ACTIVE_SERVICE} ];then
    delete_service
  else
    echo "Service was already deleted"
  fi
fi

#Post build
if [ "$CODEBUILD_BUILD_SUCCEEDING" == "0" ]; then echo "BUILD process failed; skipping POST_BUILD"; exit 1; fi #Stop if BUILD part has failed
# update Route53
export HOSTEDZONEID=$(aws route53 list-hosted-zones --output json  | jq -r ".HostedZones[]|select(.Name==\"${REPO_NAME}.${HOSTEDZONENAME}.\").Id")
export HOSTEDZONEID=${HOSTEDZONEID##*/} #Get and escape ID of Route53 zone
echo "HOSTEDZONEID -> $HOSTEDZONEID, IMAGE_TAG -> $IMAGE_TAG, MERGED_IMAGE_TAG -> $MERGED_IMAGE_TAG"
export ALB_URL=`aws elbv2 describe-load-balancers --names ${LOAD_BALANCER} | jq -r .LoadBalancers[].DNSName` #Get LB ARN
#echo "ALB_URL=$ALB_URL"
echo "CODEBUILD_WEBHOOK_EVENT=$CODEBUILD_WEBHOOK_EVENT"
if [[ -z "$ALB_URL" ]]; then echo "Couldn't find load balancer URL!"; exit 1; fi

#If EVENT="CREATE" - use UPSET to create DNS records
if [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_CREATED" ]]; then 
    echo "CREATING Route53 records for service ${SERVICE_NAME}"

    ENVS="dev-a dev-b dev-c dev-d stage" #List of envs for BE
    JSON_DATA=""
    for e in $ENVS; do
      JSON_DATA="${JSON_DATA} {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$e-$IMAGE_TAG.$REPO_NAME.$HOSTEDZONENAME.\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
      }
    },
    "
    done
  JSON_DATA="{
  \"Comment\": \"$IMAGE_TAG $IMAGE_REPO_NAME\",
  \"Changes\": [
    ${JSON_DATA} {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"*.$IMAGE_TAG.$REPO_NAME.$HOSTEDZONENAME.\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
        }
      },
      {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$IMAGE_TAG.$REPO_NAME.$HOSTEDZONENAME.\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
        }
      }
    ]
  }
"
  echo $JSON_DATA > /tmp/$HOSTEDZONEID-update.json #Savinf JSON_DATA into tmp file
  aws route53 change-resource-record-sets --hosted-zone-id $HOSTEDZONEID --change-batch file:///tmp/$HOSTEDZONEID-update.json && echo "Records updated"
  #If EVENT="UPDATE" - use UPSET to update or create DNS records
elif [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_UPDATED" ]]; then 
  echo "UPDATING Route53 records for service ${SERVICE_NAME}"
  ENVS="dev-a dev-b dev-c dev-d stage" #List of envs for BE
  JSON_DATA=""
  for e in $ENVS; do
  JSON_DATA="${JSON_DATA} {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$e-$IMAGE_TAG.$REPO_NAME.$HOSTEDZONENAME.\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
      }
    },
  "
  done
  JSON_DATA="{
    \"Comment\": \"$IMAGE_TAG $IMAGE_REPO_NAME\",
    \"Changes\": [
    ${JSON_DATA} {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"*.$IMAGE_TAG.$REPO_NAME.$HOSTEDZONENAME.\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
        }
      },
      {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$IMAGE_TAG.$REPO_NAME.$HOSTEDZONENAME.\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
        }
      }
    ]
  }
"
  echo $JSON_DATA > /tmp/$HOSTEDZONEID-update.json
  cat /tmp/$HOSTEDZONEID-update.json
  aws route53 change-resource-record-sets --hosted-zone-id $HOSTEDZONEID --change-batch file:///tmp/$HOSTEDZONEID-update.json && echo "Records updated"
  #If EVENT="MERGE|CLOSE" - use DELETE to remove DNS records
elif [[ ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_MERGED" || ${CODEBUILD_WEBHOOK_EVENT} == "PULL_REQUEST_CLOSED" ]]; then 
echo "DELETING Route53 records for service ${SERVICE_NAME}"
RECORDS=`aws route53 list-resource-record-sets --hosted-zone-id $HOSTEDZONEID | jq -r '.ResourceRecordSets[].Name' | grep $IMAGE_TAG` #Check existing DNS records for this service
if [[ -z "$RECORDS" ]]; then echo "Couldn't find DNS RECORDS; finishing post_build"; exit 0; fi
JSON_DATA=""
#Generate JSON
for e in $RECORDS; do 
  JSON_DATA="${JSON_DATA} {
      \"Action\": \"DELETE\",
      \"ResourceRecordSet\": {
        \"Name\": \"$e\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [ { \"Value\": \"$ALB_URL\" } ]
      }
    },"
done
JSON_DATA=${JSON_DATA%,*}
JSON_DATA="{
  \"Comment\": \"$IMAGE_TAG $IMAGE_REPO_NAME\",
  \"Changes\": [
    ${JSON_DATA}    
    ]
  }
"
echo $JSON_DATA > /tmp/$HOSTEDZONEID-update.json
sed -i "s/\\\052/*/g" /tmp/$HOSTEDZONEID-update.json #Replace \052 with * inside JSON
aws route53 change-resource-record-sets --hosted-zone-id $HOSTEDZONEID --change-batch file:///tmp/$HOSTEDZONEID-update.json && echo "Records deleted"
else
  echo "No POST_BUILD command found (COMMAND=$COMMAND, CODEBUILD_WEBHOOK_EVENT=$CODEBUILD_WEBHOOK_EVENT)" 
fi
