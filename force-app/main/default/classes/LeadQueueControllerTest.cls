@IsTest
private class LeadQueueControllerTest {
    @TestSetup
    static void makeData() {
        List<litify_pm__Intake__c> testIntakes = new List<litify_pm__Intake__c>{
            new litify_pm__Intake__c(
                litify_pm__Status__c = 'Lead Generated',
                Type__c = 'Personal Injury',
                Case_Type__c = 'Labor Law',
                litify_pm__Phone__c = '555-222-3333',
                litify_pm__Sign_Up_Method__c = 'Office',
                Appointment_Date__c = Datetime.now().addHours(-2),
                Follow_Up_Date_Time__c = Datetime.now().addHours(-2)
            )
        };
        insert testIntakes;
    }

    @IsTest
    static void testControllerQueueData() {
        Test.startTest();
        LeadQueueModels.QueueResponse response = LeadQueueController.getQueueData('', '', '', false);
        Test.stopTest();

        Assert.isNotNull(response, 'Response should not be null');
        Assert.isNotNull(response.stats, 'Stats should not be null');
        Assert.isNotNull(response.filters, 'Filters should not be null');
    }

    @IsTest
    static void testControllerInvalidFilters() {
        Test.startTest();
        LeadQueueModels.QueueResponse response = LeadQueueController.getQueueData('Invalid Status', '', '', false);
        Test.stopTest();

        Assert.isFalse(response.success, 'Invalid status should return unsuccessful response');
        Assert.isTrue(response.errorMessage.contains('Invalid status filter'), 'Should indicate invalid status filter');
    }

    @IsTest
    static void testControllerAssignmentEndpoints() {
        Test.startTest();
        LeadQueueModels.AssignmentResult invalidAssign = LeadQueueController.assignRecord('invalid-id');
        Boolean releaseResult = LeadQueueController.releaseUserAssignments(null);
        Map<String, Long> assignmentData = LeadQueueController.getUserAssignmentData();
        List<String> assignedIds = LeadQueueController.getUserAssignedRecordIds();
        LeadQueueModels.AssignedRecordSummary summary = LeadQueueController.getAssignedRecordSummary('invalid-id');
        Boolean cacheConfigured = LeadQueueController.isCacheConfigured();
        Test.stopTest();

        Assert.isFalse(invalidAssign.success, 'Invalid record ID should fail assignment');
        Assert.isTrue(invalidAssign.message.contains('Invalid record ID format'), 'Should indicate invalid ID format');
        Assert.isTrue(releaseResult, 'Release should return true');
        Assert.isNotNull(assignmentData, 'Assignment data should not be null');
        Assert.isNotNull(assignedIds, 'Assigned IDs should not be null');
        Assert.isNull(summary, 'Invalid record summary should return null');
        Assert.isNotNull(cacheConfigured, 'Cache configured flag should not be null');
    }

    @IsTest
    static void testControllerPagedQueueData() {
        Test.startTest();
        LeadQueueModels.QueueResponse response = LeadQueueController.getQueueDataPaged('', '', '', false, 1, 50, null, true);
        Test.stopTest();

        Assert.isNotNull(response, 'Paged response should not be null');
        Assert.isNotNull(response.stats, 'Stats should not be null');
    }
}
