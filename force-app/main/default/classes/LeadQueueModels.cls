public class LeadQueueModels {
    public class QueueResponse {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public List<QueueRecord> records { get; set; }
        @AuraEnabled public QueueStats stats { get; set; }
        @AuraEnabled public FilterOptions filters { get; set; }
        @AuraEnabled public Map<String, List<String>> tileStatusGroups { get; set; }
        @AuraEnabled public Integer listTotalRecords { get; set; }

        public QueueResponse(List<QueueRecord> records, QueueStats stats, FilterOptions filters, Map<String, List<String>> tileStatusGroups, Integer listTotalRecords) {
            this.success = true;
            this.records = records;
            this.stats = stats;
            this.filters = filters;
            this.tileStatusGroups = tileStatusGroups;
            this.listTotalRecords = listTotalRecords != null ? listTotalRecords : 0;
        }

        public QueueResponse(String errorMessage) {
            this.success = false;
            this.errorMessage = errorMessage;
            this.records = new List<QueueRecord>();
            this.stats = new QueueStats();
            this.filters = new FilterOptions();
            this.tileStatusGroups = new Map<String, List<String>>();
            this.listTotalRecords = 0;
        }
    }

    public class QueueResponseCache {
        public List<QueueRecordCache> records { get; set; }
        public QueueStats stats { get; set; }
        public FilterOptions filters { get; set; }
        public Map<String, List<String>> tileStatusGroups { get; set; }
        public Integer listTotalRecords { get; set; }

        public QueueResponseCache fromResponse(QueueResponse response) {
            this.records = new List<QueueRecordCache>();
            this.stats = response.stats;
            this.filters = response.filters;
            this.tileStatusGroups = response.tileStatusGroups;
            this.listTotalRecords = response.listTotalRecords;
            if (response.records != null) {
                for (QueueRecord record : response.records) {
                    QueueRecordCache cachedRecord = new QueueRecordCache().fromRecord(record);
                    if (cachedRecord != null) {
                        this.records.add(cachedRecord);
                    }
                }
            }
            return this;
        }

        public QueueResponse toResponse() {
            List<QueueRecord> restored = new List<QueueRecord>();
            if (records != null) {
                for (QueueRecordCache cached : records) {
                    QueueRecord record = cached.toRecord();
                    if (record != null) {
                        restored.add(record);
                    }
                }
            }
            return new QueueResponse(restored, stats, filters, tileStatusGroups, listTotalRecords);
        }
    }

    public class QueueRecordCache {
        public String recordId { get; set; }
        public String displayName { get; set; }
        public String referredByName { get; set; }
        public String status { get; set; }
        public String caseType { get; set; }
        public String qualificationStatus { get; set; }
        public Datetime callAtDate { get; set; }
        public String phone { get; set; }
        public Integer priorityScore { get; set; }
        public Boolean isHighPriority { get; set; }
        public Boolean isDueToday { get; set; }
        public Boolean isOverdue { get; set; }
        public Boolean isAssigned { get; set; }
        public String assignedTo { get; set; }
        public Long assignedTimestamp { get; set; }

        public QueueRecordCache fromRecord(QueueRecord record) {
            if (record == null || record.record == null) {
                return null;
            }
            this.recordId = String.valueOf(record.record.Id);
            this.displayName = record.displayName != null ? record.displayName : record.record.litify_pm__Display_Name__c;
            this.referredByName = record.referredByName != null ? record.referredByName : record.record.Referred_By_Name__c;
            this.status = record.status != null ? record.status : record.record.litify_pm__Status__c;
            this.caseType = record.caseType != null ? record.caseType : record.record.Queue_Case_Type__c;
            this.qualificationStatus = record.qualificationStatus != null ? record.qualificationStatus : record.record.Qualification_Status__c;
            this.callAtDate = record.callAtDate != null ? record.callAtDate : record.record.Call_at_Date__c;
            this.phone = record.phone != null ? record.phone : record.record.litify_pm__Phone__c;
            this.priorityScore = record.priorityScore;
            this.isHighPriority = record.isHighPriority;
            this.isDueToday = record.isDueToday;
            this.isOverdue = record.isOverdue;
            this.isAssigned = record.isAssigned;
            this.assignedTo = record.assignedTo;
            this.assignedTimestamp = record.assignedTimestamp;
            return this;
        }

        public QueueRecord toRecord() {
            if (String.isBlank(recordId)) {
                return null;
            }
            litify_pm__Intake__c restored = new litify_pm__Intake__c();
            restored.Id = (Id) recordId;

            QueueRecord record = new QueueRecord();
            record.record = restored;
            record.recordId = recordId;
            record.displayName = displayName;
            record.referredByName = referredByName;
            record.status = status;
            record.caseType = caseType;
            record.qualificationStatus = qualificationStatus;
            record.callAtDate = callAtDate;
            record.phone = phone;
            record.priorityScore = priorityScore;
            record.isHighPriority = isHighPriority;
            record.isDueToday = isDueToday;
            record.isOverdue = isOverdue;
            record.isAssigned = isAssigned != null ? isAssigned : String.isNotBlank(assignedTo);
            record.assignedTo = assignedTo;
            record.assignedTimestamp = assignedTimestamp;
            return record;
        }
    }

    public class QueueRecord {
        @AuraEnabled public litify_pm__Intake__c record { get; set; }
        @AuraEnabled public String recordId { get; set; }
        @AuraEnabled public String displayName { get; set; }
        @AuraEnabled public String referredByName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String caseType { get; set; }
        @AuraEnabled public String qualificationStatus { get; set; }
        @AuraEnabled public Datetime callAtDate { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public Integer priorityScore { get; set; }
        @AuraEnabled public Boolean isHighPriority { get; set; }
        @AuraEnabled public Boolean isDueToday { get; set; }
        @AuraEnabled public Boolean isOverdue { get; set; }
        @AuraEnabled public Boolean isAssigned { get; set; }
        @AuraEnabled public String assignedTo { get; set; }
        @AuraEnabled public Long assignedTimestamp { get; set; }
    }

    public class QueueStats {
        @AuraEnabled public Integer totalRecords { get; set; }
        @AuraEnabled public Integer highPriorityCount { get; set; }
        @AuraEnabled public Integer inContactCount { get; set; }
        @AuraEnabled public Integer noContactCount { get; set; }
        @AuraEnabled public Integer retainerSentCount { get; set; }
        @AuraEnabled public Integer referralCount { get; set; }

        public QueueStats() {
            this.totalRecords = 0;
            this.highPriorityCount = 0;
            this.inContactCount = 0;
            this.noContactCount = 0;
            this.retainerSentCount = 0;
            this.referralCount = 0;
        }
    }

    public class FilterOptions {
        @AuraEnabled public List<PicklistOption> statusOptions { get; set; }
        @AuraEnabled public List<PicklistOption> caseTypeOptions { get; set; }
    }

    public class PicklistOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }

        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class AssignmentResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String recordId { get; set; }
        @AuraEnabled public String recordName { get; set; }

        public AssignmentResult(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    public class AssignedRecordSummary {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String displayName { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class ValidationResult {
        public Boolean isValid { get; set; }
        public String errorMessage { get; set; }

        public ValidationResult(Boolean isValid, String errorMessage) {
            this.isValid = isValid;
            this.errorMessage = errorMessage;
        }
    }
}
