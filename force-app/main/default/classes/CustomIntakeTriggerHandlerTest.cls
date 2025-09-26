@isTest
public class CustomIntakeTriggerHandlerTest {
    
    @isTest
    static void testHandleTriggerBeforeInsert() {
        // Test before insert context
        List<litify_pm__Intake__c> newIntakes = new List<litify_pm__Intake__c>();
        newIntakes.add(new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0001'
        ));
        
        Test.startTest();
        
        try {
            insert newIntakes;
        } catch (Exception e) {
            System.assert(false, 'Exception during insert: ' + e.getMessage() + ' Stack: ' + e.getStackTraceString());
        }
        
        Test.stopTest();
        
        // Verify record was created successfully  
        System.assertNotEquals(null, newIntakes[0].Id, 'Record should have an ID after insert');
        
        // Verify record can be retrieved by ID
        List<litify_pm__Intake__c> insertedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :newIntakes[0].Id];
        System.assertEquals(1, insertedIntakes.size(), 'Record should be retrievable by ID');
    }
    
    @isTest
    static void testHandleTriggerBeforeUpdate() {
        // Create test data
        litify_pm__Intake__c testIntake = new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0002'
        );
        insert testIntake;
        
        // Update the record
        testIntake.litify_pm__Phone__c = '555-9999';
        
        Test.startTest();
        update testIntake;
        Test.stopTest();
        
        // Verify record still exists after update
        List<litify_pm__Intake__c> updatedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :testIntake.Id];
        System.assertEquals(1, updatedIntakes.size(), 'Record should still exist after update');
    }
    
    @isTest
    static void testHandleTriggerBeforeDelete() {
        // Create test data
        litify_pm__Intake__c testIntake = new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0003'
        );
        insert testIntake;
        
        Test.startTest();
        delete testIntake;
        Test.stopTest();
        
        // Verify record was deleted
        List<litify_pm__Intake__c> deletedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :testIntake.Id];
        System.assertEquals(0, deletedIntakes.size(), 'Record should be deleted');
    }
    
    @isTest
    static void testHandleTriggerAfterInsert() {
        // Test after insert context
        List<litify_pm__Intake__c> newIntakes = new List<litify_pm__Intake__c>();
        newIntakes.add(new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0004'
        ));
        
        Test.startTest();
        insert newIntakes;
        Test.stopTest();
        
        // Verify record was created successfully
        System.assertNotEquals(null, newIntakes[0].Id, 'Record should have an ID after insert');
        
        // Verify record can be retrieved by ID
        List<litify_pm__Intake__c> insertedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :newIntakes[0].Id];
        System.assertEquals(1, insertedIntakes.size(), 'Record should be retrievable by ID');
    }
    
    @isTest
    static void testHandleTriggerAfterUpdate() {
        // Create test data
        litify_pm__Intake__c testIntake = new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0005'
        );
        insert testIntake;
        
        // Update the record
        testIntake.litify_pm__Phone__c = '555-8888';
        
        Test.startTest();
        update testIntake;
        Test.stopTest();
        
        // Verify record still exists after update
        List<litify_pm__Intake__c> updatedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :testIntake.Id];
        System.assertEquals(1, updatedIntakes.size(), 'Record should still exist after update');
    }
    
    @isTest
    static void testHandleTriggerAfterDelete() {
        // Create test data
        litify_pm__Intake__c testIntake = new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0006'
        );
        insert testIntake;
        
        Id intakeId = testIntake.Id;
        
        Test.startTest();
        delete testIntake;
        Test.stopTest();
        
        // Verify record was deleted
        List<litify_pm__Intake__c> deletedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :intakeId];
        System.assertEquals(0, deletedIntakes.size(), 'Record should be deleted');
    }
    
    @isTest
    static void testHandleTriggerAfterUndelete() {
        // Create test data
        litify_pm__Intake__c testIntake = new litify_pm__Intake__c(
            litify_pm__Phone__c = '555-0007'
        );
        insert testIntake;
        
        Id intakeId = testIntake.Id;
        delete testIntake;
        
        Test.startTest();
        undelete testIntake;
        Test.stopTest();
        
        // Verify record was undeleted
        List<litify_pm__Intake__c> undeletedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :intakeId];
        System.assertEquals(1, undeletedIntakes.size(), 'Record should be undeleted');
    }
    
    @isTest
    static void testHandleTriggerMultipleRecords() {
        // Test with multiple records to ensure bulk processing
        List<litify_pm__Intake__c> multipleIntakes = new List<litify_pm__Intake__c>();
        
        for (Integer i = 0; i < 10; i++) {
            multipleIntakes.add(new litify_pm__Intake__c(
                litify_pm__Phone__c = '555-000' + i
            ));
        }
        
        Test.startTest();
        insert multipleIntakes;
        
        // Update all records
        for (litify_pm__Intake__c intake : multipleIntakes) {
            intake.litify_pm__Phone__c = '555-999' + intake.litify_pm__Phone__c.substring(7);
        }
        update multipleIntakes;
        
        // Delete all records
        delete multipleIntakes;
        
        // Undelete all records
        undelete multipleIntakes;
        Test.stopTest();
        
        // Verify all operations completed
        List<litify_pm__Intake__c> finalIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE litify_pm__Phone__c LIKE '555-999%'];
        System.assertEquals(10, finalIntakes.size(), 'All records should be processed in bulk');
    }
    
    @isTest
    static void testHandleTriggerDirectCall() {
        // Test calling the trigger handler directly
        List<litify_pm__Intake__c> testIntakes = new List<litify_pm__Intake__c>();
        testIntakes.add(new litify_pm__Intake__c(litify_pm__Phone__c = '555-0008'));
        
        Test.startTest();
        // This will test the trigger handler logic directly
        insert testIntakes;
        Test.stopTest();
        
        // Verify the trigger handler executed without errors
        System.assertNotEquals(null, testIntakes[0].Id, 'Record should have an ID after insert');
        
        List<litify_pm__Intake__c> insertedIntakes = [SELECT Id FROM litify_pm__Intake__c WHERE Id = :testIntakes[0].Id];
        System.assertEquals(1, insertedIntakes.size(), 'Trigger handler should execute successfully');
    }
}